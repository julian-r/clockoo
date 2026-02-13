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
