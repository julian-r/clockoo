import Foundation

/// Detected capabilities of the Odoo instance
struct OdooCapabilities: Sendable {
    var hasHelpdeskTicketId: Bool = false
    /// Odoo 18 and earlier use timer.timer model separately from timesheets.
    /// The timesheet is only created when the timer is stopped.
    var hasTimerTimerModel: Bool = false
}

/// Service layer for fetching and controlling Odoo timesheets/timers
final class OdooTimerService: Sendable {
    let client: OdooJSONRPCClient
    let accountId: String

    private static let timesheetModel = "account.analytic.line"

    /// Base fields that always exist on account.analytic.line
    private static let baseFields = [
        "name", "project_id", "task_id",
        "unit_amount", "timer_start", "date",
    ]

    private let capabilities = ManagedAtomic<OdooCapabilities?>(nil)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    init(client: OdooJSONRPCClient, accountId: String) {
        self.client = client
        self.accountId = accountId
    }

    // MARK: - Capability Detection

    /// Probe the Odoo instance to detect installed modules.
    /// Called once per account, results are cached.
    func detectCapabilities() async throws -> OdooCapabilities {
        if let cached = capabilities.value {
            return cached
        }

        var caps = OdooCapabilities()

        // Probe for helpdesk_ticket_id by requesting it — error if not available
        caps.hasHelpdeskTicketId = await probeField("helpdesk_ticket_id")

        // Probe for timer.timer model (Odoo 14-18 use this for running timers)
        caps.hasTimerTimerModel = await probeModel("timer.timer")

        capabilities.value = caps
        print("[OdooTimer:\(accountId)] helpdesk=\(caps.hasHelpdeskTicketId) timer.timer=\(caps.hasTimerTimerModel)")
        return caps
    }

    private func probeField(_ field: String) async -> Bool {
        do {
            _ = try await client.searchRead(
                model: Self.timesheetModel,
                domain: [],
                fields: ["id", field],
                limit: 1
            )
            return true
        } catch {
            return false
        }
    }

    private func probeModel(_ model: String) async -> Bool {
        do {
            _ = try await client.searchRead(
                model: model,
                domain: [],
                fields: ["id"],
                limit: 1
            )
            return true
        } catch {
            return false
        }
    }

    private func fieldsToFetch() async throws -> [String] {
        let caps = try await detectCapabilities()
        var fields = Self.baseFields
        if caps.hasHelpdeskTicketId {
            fields.append("helpdesk_ticket_id")
        }
        return fields
    }

    // MARK: - Fetching

    /// Fetch today's timesheets for the current user.
    /// Filters for active timers (timer_start set) client-side to avoid
    /// domain compatibility issues across Odoo versions.
    func fetchActiveTimesheets() async throws -> [Timesheet] {
        let all = try await fetchTodayTimesheets()
        return all.filter { $0.timerStart != nil }
    }

    /// Fetch all of today's timesheets (running, paused, and stopped)
    /// Also checks timer.timer for running timers that haven't created a timesheet yet (Odoo 14-18)
    func fetchTodayTimesheets() async throws -> [Timesheet] {
        let uid = try await client.authenticate()
        let today = Self.dateOnlyFormatter.string(from: Date())
        let fields = try await fieldsToFetch()
        let caps = try await detectCapabilities()

        let domain: [[Any]] = [
            ["user_id", "=", uid],
            ["date", "=", today],
        ]

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: domain,
            fields: fields
        )

        var timesheets = records.compactMap { parseTimesheet($0) }

        // Odoo 14-18: check timer.timer for running timers without a timesheet yet
        if caps.hasTimerTimerModel {
            let runningTimers = try await fetchRunningTimerTimers(uid: uid)
            // Only add timers that don't already have a matching timesheet
            let existingTaskIds = Set(timesheets.compactMap { ts -> Int? in
                if case .task(let id, _) = ts.source { return id }
                return nil
            })
            let existingTicketIds = Set(timesheets.compactMap { ts -> Int? in
                if case .ticket(let id, _) = ts.source { return id }
                return nil
            })
            for timer in runningTimers {
                switch timer.source {
                case .task(let id, _) where existingTaskIds.contains(id): continue
                case .ticket(let id, _) where existingTicketIds.contains(id): continue
                default: timesheets.append(timer)
                }
            }
        }

        return timesheets
    }

    /// Fetch running timers from timer.timer model (Odoo 14-18)
    /// These are timers that haven't created a timesheet yet
    private func fetchRunningTimerTimers(uid: Int) async throws -> [Timesheet] {
        let timerRecords = try await client.searchRead(
            model: "timer.timer",
            domain: [
                ["user_id", "=", uid],
                ["timer_start", "!=", false],
                ["timer_pause", "=", false],
            ],
            fields: ["timer_start", "res_model", "res_id"]
        )

        var timesheets: [Timesheet] = []
        for record in timerRecords {
            guard let resModel = record["res_model"] as? String,
                  let resId = record["res_id"] as? Int,
                  let timerStart = parseOdooDatetime(record["timer_start"])
            else { continue }

            // Fetch the parent record name
            let source: TimerSource
            let projectName: String?

            if resModel == "project.task" {
                let taskRecords = try? await client.searchRead(
                    model: "project.task",
                    domain: [["id", "=", resId]],
                    fields: ["display_name", "project_id"],
                    limit: 1
                )
                let name = taskRecords?.first?["display_name"] as? String ?? "Task #\(resId)"
                let proj = parseManyToOne(taskRecords?.first?["project_id"])
                source = .task(id: resId, name: name)
                projectName = proj?.name
            } else if resModel == "helpdesk.ticket" {
                let ticketRecords = try? await client.searchRead(
                    model: "helpdesk.ticket",
                    domain: [["id", "=", resId]],
                    fields: ["display_name"],
                    limit: 1
                )
                let name = ticketRecords?.first?["display_name"] as? String ?? "Ticket #\(resId)"
                source = .ticket(id: resId, name: name)
                projectName = nil
            } else {
                continue
            }

            // Use negative timer ID as placeholder (no real timesheet exists yet)
            let timerId = -(record["id"] as? Int ?? resId)
            timesheets.append(Timesheet(
                id: timerId,
                accountId: accountId,
                name: "",
                projectName: projectName,
                source: source,
                unitAmount: 0,
                timerStart: timerStart,
                date: Self.dateOnlyFormatter.string(from: Date())
            ))
        }
        return timesheets
    }

    // MARK: - Timer Actions
    // These call the methods on account.analytic.line from timesheet_grid/timer.mixin

    func startTimer(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "action_timer_start", ids: [timesheetId]
        )
    }

    func stopTimer(timesheetId: Int) async throws {
        if timesheetId < 0 {
            // Negative ID = timer.timer placeholder, stop via parent model
            // The timer.timer record ID is the absolute value
            let timerRecords = try await client.searchRead(
                model: "timer.timer",
                domain: [["id", "=", -timesheetId]],
                fields: ["res_model", "res_id"],
                limit: 1
            )
            if let record = timerRecords.first,
               let resModel = record["res_model"] as? String,
               let resId = record["res_id"] as? Int {
                try await client.callMethod(
                    model: resModel, method: "action_timer_stop", ids: [resId]
                )
            }
        } else {
            try await client.callMethod(
                model: Self.timesheetModel, method: "action_timer_stop", ids: [timesheetId]
            )
        }
    }

    // Note: Odoo's task UI only has Start/Stop — no Pause/Resume.
    // The timer.mixin has pause/resume methods but the task form doesn't expose them.

    func deleteTimesheet(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "unlink", ids: [timesheetId]
        )
    }

    // MARK: - Search

    /// Search result item for display in the search UI
    struct SearchResult: Identifiable, Sendable {
        enum Kind: Sendable { case task, ticket, recentTimesheet }
        let id: Int
        let name: String
        let kind: Kind
        let projectName: String?
        /// For recent timesheets, the existing timesheet ID to restart
        let timesheetId: Int?
    }

    /// Search tasks by name. Filters: allow_timesheets, not cancelled/done stages.
    func searchTasks(query: String, limit: Int = 7) async throws -> [SearchResult] {
        let uid = try await client.authenticate()
        let domain: [[Any]] = query.isEmpty
            ? [["user_ids", "in", [uid]], ["allow_timesheets", "=", true]]
            : [["allow_timesheets", "=", true]]

        let results = try await client.nameSearch(
            model: "project.task", name: query, domain: domain, limit: limit
        )
        // name_search only returns (id, display_name). Fetch project names.
        guard !results.isEmpty else { return [] }
        let ids = results.map { $0.id }
        let records = try await client.searchRead(
            model: "project.task",
            domain: [["id", "in", ids]],
            fields: ["id", "project_id"]
        )
        let projectById = Dictionary(uniqueKeysWithValues: records.compactMap { r -> (Int, String)? in
            guard let id = r["id"] as? Int,
                  let proj = r["project_id"] as? [Any], proj.count >= 2,
                  let projName = proj[1] as? String
            else { return nil }
            return (id, projName)
        })
        return results.map { r in
            SearchResult(id: r.id, name: r.name, kind: .task,
                         projectName: projectById[r.id], timesheetId: nil)
        }
    }

    /// Search helpdesk tickets by name.
    func searchTickets(query: String, limit: Int = 5) async throws -> [SearchResult] {
        let caps = try await detectCapabilities()
        guard caps.hasHelpdeskTicketId else { return [] }

        let results = try await client.nameSearch(
            model: "helpdesk.ticket", name: query, domain: [], limit: limit
        )
        return results.map { r in
            SearchResult(id: r.id, name: r.name, kind: .ticket,
                         projectName: nil, timesheetId: nil)
        }
    }

    /// Search recent timesheets (last 7 days), deduped by task/ticket.
    func searchRecentTimesheets(query: String, limit: Int = 5) async throws -> [SearchResult] {
        let uid = try await client.authenticate()
        let fields = try await fieldsToFetch()

        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let fromDate = Self.dateOnlyFormatter.string(from: sevenDaysAgo)

        let domain: [[Any]] = [
            ["user_id", "=", uid],
            ["date", ">=", fromDate],
        ]

        let records = try await client.searchRead(
            model: Self.timesheetModel, domain: domain, fields: fields, limit: 50
        )

        // Dedupe by task/ticket, prefer most recent, filter by query client-side
        let lowerQuery = query.lowercased()
        var seen = Set<String>()
        var results: [SearchResult] = []
        for record in records {
            guard let ts = parseTimesheet(record) else { continue }
            // Client-side filter: match query against task/ticket name or project
            if !query.isEmpty {
                let matchLabel = ts.displayLabel.lowercased().contains(lowerQuery)
                let matchProject = ts.projectName?.lowercased().contains(lowerQuery) ?? false
                guard matchLabel || matchProject else { continue }
            }
            let key: String
            switch ts.source {
            case .task(let id, _): key = "task-\(id)"
            case .ticket(let id, _): key = "ticket-\(id)"
            case .standalone: key = "ts-\(ts.id)"
            }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(SearchResult(
                id: ts.source.sourceId,
                name: ts.displayLabel,
                kind: .recentTimesheet,
                projectName: ts.projectName,
                timesheetId: ts.id
            ))
            if results.count >= limit { break }
        }
        return results
    }

    /// Start a timer on a task (creates timesheet + starts timer)
    func startTimerOnTask(taskId: Int) async throws {
        try await client.callMethod(
            model: "project.task", method: "action_timer_start", ids: [taskId]
        )
    }

    /// Start a timer on a helpdesk ticket (creates timesheet + starts timer)
    func startTimerOnTicket(ticketId: Int) async throws {
        try await client.callMethod(
            model: "helpdesk.ticket", method: "action_timer_start", ids: [ticketId]
        )
    }

    // MARK: - Parsing

    private func parseTimesheet(_ record: [String: Any]) -> Timesheet? {
        guard let id = record["id"] as? Int else { return nil }

        let name = record["name"] as? String ?? ""
        let projectName = parseManyToOne(record["project_id"])?.name
        let source = parseSource(record)
        let unitAmount = record["unit_amount"] as? Double ?? 0
        let timerStart = parseOdooDatetime(record["timer_start"])
        let date = record["date"] as? String ?? ""

        return Timesheet(
            id: id,
            accountId: accountId,
            name: name,
            projectName: projectName,
            source: source,
            unitAmount: unitAmount,
            timerStart: timerStart,
            date: date
        )
    }

    private func parseSource(_ record: [String: Any]) -> TimerSource {
        if let task = parseManyToOne(record["task_id"]) {
            return .task(id: task.id, name: task.name)
        }
        if let ticket = parseManyToOne(record["helpdesk_ticket_id"]) {
            return .ticket(id: ticket.id, name: ticket.name)
        }
        return .standalone
    }

    private func parseManyToOne(_ value: Any?) -> (id: Int, name: String)? {
        guard let arr = value as? [Any],
              arr.count >= 2,
              let id = arr[0] as? Int,
              let name = arr[1] as? String
        else { return nil }
        return (id, name)
    }

    private func parseOdooDatetime(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        return Self.dateFormatter.date(from: str)
    }
}
