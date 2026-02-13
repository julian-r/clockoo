import Foundation

/// Detected capabilities of the Odoo instance
struct OdooCapabilities: Sendable {
    var hasHelpdeskTicketId: Bool = false
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

        // Probe for helpdesk_ticket_id by requesting it — 500 if not available
        caps.hasHelpdeskTicketId = await probeField("helpdesk_ticket_id")

        capabilities.value = caps
        print("[OdooTimer:\(accountId)] helpdesk=\(caps.hasHelpdeskTicketId)")
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
    func fetchTodayTimesheets() async throws -> [Timesheet] {
        let uid = try await client.authenticate()
        let today = Self.dateOnlyFormatter.string(from: Date())
        let fields = try await fieldsToFetch()

        let domain: [[Any]] = [
            ["user_id", "=", uid],
            ["date", "=", today],
        ]

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: domain,
            fields: fields
        )

        return records.compactMap { parseTimesheet($0) }
    }

    // MARK: - Timer Actions
    // These call the methods on account.analytic.line from timesheet_grid/timer.mixin

    func startTimer(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "action_timer_start", ids: [timesheetId]
        )
    }

    func stopTimer(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "action_timer_stop", ids: [timesheetId]
        )
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
