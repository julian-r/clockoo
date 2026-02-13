import Foundation

/// Service layer for fetching and controlling Odoo timesheets/timers
final class OdooTimerService: Sendable {
    let client: OdooJSONRPCClient
    let accountId: String

    private static let timesheetModel = "account.analytic.line"

    private static let fields = [
        "name", "project_id", "task_id", "helpdesk_ticket_id",
        "unit_amount", "timer_start", "timer_pause", "date",
    ]

    /// Odoo datetime format
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

    /// Fetch today's active timesheets (those with timer_start set)
    func fetchActiveTimesheets() async throws -> [Timesheet] {
        let uid = try await client.authenticate()
        let today = Self.dateOnlyFormatter.string(from: Date())

        let domain: [[Any]] = [
            ["user_id", "=", uid],
            ["timer_start", "!=", false],
            ["date", "=", today],
        ]

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: domain,
            fields: Self.fields
        )

        return records.compactMap { record in
            parseTimesheet(record)
        }
    }

    /// Fetch all of today's timesheets (including stopped ones)
    func fetchTodayTimesheets() async throws -> [Timesheet] {
        let uid = try await client.authenticate()
        let today = Self.dateOnlyFormatter.string(from: Date())

        let domain: [[Any]] = [
            ["user_id", "=", uid],
            ["date", "=", today],
        ]

        let records = try await client.searchRead(
            model: Self.timesheetModel,
            domain: domain,
            fields: Self.fields
        )

        return records.compactMap { record in
            parseTimesheet(record)
        }
    }

    // MARK: - Timer Actions

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

    func pauseTimer(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "action_timer_pause", ids: [timesheetId]
        )
    }

    func resumeTimer(timesheetId: Int) async throws {
        try await client.callMethod(
            model: Self.timesheetModel, method: "action_timer_resume", ids: [timesheetId]
        )
    }

    // MARK: - Parsing

    private func parseTimesheet(_ record: [String: Any]) -> Timesheet? {
        guard let id = record["id"] as? Int else { return nil }

        let name = record["name"] as? String ?? ""

        // Parse many2one fields: they come as [id, "name"] or false
        let projectName = parseManyToOne(record["project_id"])?.name
        let source = parseSource(record)

        let unitAmount = record["unit_amount"] as? Double ?? 0
        let timerStart = parseOdooDatetime(record["timer_start"])
        let timerPause = parseOdooDatetime(record["timer_pause"])
        let date = record["date"] as? String ?? ""

        return Timesheet(
            id: id,
            accountId: accountId,
            name: name,
            projectName: projectName,
            source: source,
            unitAmount: unitAmount,
            timerStart: timerStart,
            timerPause: timerPause,
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
