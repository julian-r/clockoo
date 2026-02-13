import Foundation

/// Detected capabilities of the Odoo instance
struct OdooCapabilities: Sendable {
    var hasHelpdeskTicketId: Bool = false
}

/// Service layer for fetching and controlling Odoo timesheets/timers.
/// Delegates version-specific behavior to an ``OdooTimerBackend``.
final class OdooTimerService: Sendable {
    let client: OdooClient
    let backend: OdooTimerBackend
    let accountId: String

    private static let timesheetModel = "account.analytic.line"

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

    init(client: OdooClient, backend: OdooTimerBackend, accountId: String) {
        self.client = client
        self.backend = backend
        self.accountId = accountId
    }

    // MARK: - Capability Detection

    func detectCapabilities() async throws -> OdooCapabilities {
        if let cached = capabilities.value { return cached }

        var caps = OdooCapabilities()
        caps.hasHelpdeskTicketId = await probeField("helpdesk_ticket_id")
        capabilities.value = caps
        print("[OdooTimer:\(accountId)] helpdesk=\(caps.hasHelpdeskTicketId)")
        return caps
    }

    private func probeField(_ field: String) async -> Bool {
        do {
            _ = try await client.searchRead(
                model: Self.timesheetModel, domain: [], fields: ["id", field], limit: 1)
            return true
        } catch { return false }
    }

    private func fieldsToFetch() async throws -> [String] {
        let caps = try await detectCapabilities()
        var fields = Self.baseFields
        if caps.hasHelpdeskTicketId { fields.append("helpdesk_ticket_id") }
        return fields
    }

    // MARK: - Fetching

    func fetchActiveTimesheets() async throws -> [Timesheet] {
        try await fetchTodayTimesheets().filter { $0.timerStart != nil }
    }

    func fetchTodayTimesheets() async throws -> [Timesheet] {
        let uid = try await client.authenticate()
        let today = Self.dateOnlyFormatter.string(from: Date())
        let fields = try await fieldsToFetch()

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: [["user_id", "=", uid], ["date", "=", today]],
            fields: fields
        )

        let timesheets = records.compactMap { parseTimesheet($0) }

        // Let the backend enrich with version-specific running state
        return try await backend.enrichWithRunningState(
            timesheets: timesheets, client: client, uid: uid, accountId: accountId)
    }

    // MARK: - Timer Actions

    func startTimer(timesheet: Timesheet) async throws {
        try await backend.startTimer(timesheet: timesheet, client: client)
    }

    func stopTimer(timesheet: Timesheet) async throws {
        let result = try await backend.stopTimer(timesheet: timesheet, client: client)
        try await handleStopWizardIfNeeded(result)
    }

    /// Some Odoo versions return a wizard action from action_timer_stop
    /// instead of stopping directly. We detect and complete the wizard.
    private func handleStopWizardIfNeeded(_ result: Any) async throws {
        guard let dict = result as? [String: Any],
              let resModel = dict["res_model"] as? String,
              dict["type"] as? String == "ir.actions.act_window"
        else { return }

        let context = dict["context"] as? [String: Any] ?? [:]

        if resModel == "project.task.create.timesheet" {
            // Odoo 14-18
            let taskId = context["active_id"] as? Int ?? 0
            let timeSpent = context["default_time_spent"] as? Double ?? 0
            let wizardId = try await client.create(
                model: resModel,
                values: ["task_id": taskId, "description": "/", "time_spent": timeSpent])
            _ = try await client.callMethodWithKwargs(
                model: resModel, method: "save_timesheet",
                args: [[wizardId]], kwargs: ["context": context])
            print("[Timer] Completed stop wizard (Odoo 18) for task \(taskId)")
        } else if resModel == "hr.timesheet.stop.timer.confirmation.wizard" {
            // Odoo 19
            let timesheetId = context["default_timesheet_id"] as? Int ?? 0
            let wizardId = try await client.create(
                model: resModel, values: ["timesheet_id": timesheetId])
            _ = try await client.callMethodWithKwargs(
                model: resModel, method: "action_stop_timer",
                args: [[wizardId]], kwargs: ["context": context])
            print("[Timer] Completed stop wizard (Odoo 19) for timesheet \(timesheetId)")
        } else {
            print("[Timer] Unknown stop wizard: \(resModel), ignoring")
        }
    }

    func deleteTimesheet(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "unlink", ids: [timesheetId])
    }

    // MARK: - Search

    struct SearchResult: Identifiable, Sendable {
        enum Kind: Sendable { case task, ticket, recentTimesheet }
        let id: Int
        let name: String
        let kind: Kind
        let projectName: String?
        let timesheetId: Int?
    }

    func searchTasks(query: String, limit: Int = 7) async throws -> [SearchResult] {
        let uid = try await client.authenticate()
        let domain: [[Any]] = query.isEmpty
            ? [["user_ids", "in", [uid]], ["allow_timesheets", "=", true]]
            : [["allow_timesheets", "=", true]]

        let results = try await client.nameSearch(
            model: "project.task", name: query, domain: domain, limit: limit)
        guard !results.isEmpty else { return [] }

        let ids = results.map { $0.id }
        let records = try await client.searchRead(
            model: "project.task", domain: [["id", "in", ids]], fields: ["id", "project_id"])
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

    func searchTickets(query: String, limit: Int = 5) async throws -> [SearchResult] {
        let caps = try await detectCapabilities()
        guard caps.hasHelpdeskTicketId else { return [] }
        let results = try await client.nameSearch(
            model: "helpdesk.ticket", name: query, domain: [], limit: limit)
        return results.map { r in
            SearchResult(id: r.id, name: r.name, kind: .ticket,
                         projectName: nil, timesheetId: nil)
        }
    }

    func searchRecentTimesheets(query: String, limit: Int = 5) async throws -> [SearchResult] {
        let uid = try await client.authenticate()
        let fields = try await fieldsToFetch()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let fromDate = Self.dateOnlyFormatter.string(from: sevenDaysAgo)

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: [["user_id", "=", uid], ["date", ">=", fromDate]],
            fields: fields, limit: 50)

        let lowerQuery = query.lowercased()
        var seen = Set<String>()
        var results: [SearchResult] = []
        for record in records {
            guard let ts = parseTimesheet(record) else { continue }
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
                id: ts.source.sourceId, name: ts.displayLabel, kind: .recentTimesheet,
                projectName: ts.projectName, timesheetId: ts.id))
            if results.count >= limit { break }
        }
        return results
    }

    func startTimerOnTask(taskId: Int) async throws {
        try await client.callMethod(
            model: "project.task", method: "action_timer_start", ids: [taskId])
    }

    func startTimerOnTicket(ticketId: Int) async throws {
        try await client.callMethod(
            model: "helpdesk.ticket", method: "action_timer_start", ids: [ticketId])
    }

    // MARK: - Parsing

    private func parseTimesheet(_ record: [String: Any]) -> Timesheet? {
        guard let id = record["id"] as? Int else { return nil }
        return Timesheet(
            id: id,
            accountId: accountId,
            name: record["name"] as? String ?? "",
            projectName: parseManyToOne(record["project_id"])?.name,
            source: parseSource(record),
            unitAmount: record["unit_amount"] as? Double ?? 0,
            timerStart: parseOdooDatetime(record["timer_start"]),
            date: record["date"] as? String ?? ""
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
        guard let arr = value as? [Any], arr.count >= 2,
              let id = arr[0] as? Int, let name = arr[1] as? String
        else { return nil }
        return (id, name)
    }

    private func parseOdooDatetime(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        return Self.dateFormatter.date(from: str)
    }
}
