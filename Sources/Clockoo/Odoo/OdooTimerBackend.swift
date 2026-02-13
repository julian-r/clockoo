import Foundation

/// Version-specific timer behavior for Odoo.
/// Separates *how timers work* from the transport layer (OdooClient).
///
/// - ``Odoo19TimerBackend``: Odoo 19+ — timers live directly on timesheets
/// - ``OdooLegacyTimerBackend``: Odoo 14-18 — timers live in timer.timer model
protocol OdooTimerBackend: Sendable {
    /// Enrich timesheets with running timer state.
    /// Called after fetching today's timesheets from account.analytic.line.
    /// The backend may query additional models (e.g. timer.timer) and merge state.
    func enrichWithRunningState(
        timesheets: [Timesheet],
        client: OdooClient,
        uid: Int,
        accountId: String
    ) async throws -> [Timesheet]

    /// Start a timer on a timesheet.
    func startTimer(timesheet: Timesheet, client: OdooClient) async throws

    /// Stop a timer on a timesheet. Returns any wizard action dict that
    /// needs to be completed by the caller.
    func stopTimer(timesheet: Timesheet, client: OdooClient) async throws -> Any
}

// MARK: - Odoo 19+ Backend

/// Odoo 19+: timers are managed directly on account.analytic.line.
/// timer_start on the timesheet is the source of truth.
final class Odoo19TimerBackend: OdooTimerBackend {
    func enrichWithRunningState(
        timesheets: [Timesheet], client: OdooClient, uid: Int, accountId: String
    ) async throws -> [Timesheet] {
        // No enrichment needed — timer_start on the timesheet is authoritative
        timesheets
    }

    func startTimer(timesheet: Timesheet, client: OdooClient) async throws {
        try await client.callMethod(
            model: "account.analytic.line",
            method: "action_timer_start",
            ids: [timesheet.id]
        )
    }

    func stopTimer(timesheet: Timesheet, client: OdooClient) async throws -> Any {
        try await client.callMethodReturning(
            model: "account.analytic.line",
            method: "action_timer_stop",
            ids: [timesheet.id]
        )
    }
}

// MARK: - Odoo 14-18 (Legacy) Backend

/// Odoo 14-18: running timer state lives in the timer.timer model,
/// and start/stop must go through the source model (project.task / helpdesk.ticket).
final class OdooLegacyTimerBackend: OdooTimerBackend {
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

    func enrichWithRunningState(
        timesheets: [Timesheet], client: OdooClient, uid: Int, accountId: String
    ) async throws -> [Timesheet] {
        let runningTimers = try await fetchRunningTimerTimers(
            client: client, uid: uid, accountId: accountId)

        var result = timesheets
        for timer in runningTimers {
            let sourceId = timer.source.sourceId
            let matchIndex: Int?

            switch timer.source {
            case .task:
                matchIndex = result.firstIndex { ts in
                    if case .task(let id, _) = ts.source { return id == sourceId }
                    return false
                }
            case .ticket:
                matchIndex = result.firstIndex { ts in
                    if case .ticket(let id, _) = ts.source { return id == sourceId }
                    return false
                }
            case .standalone:
                matchIndex = nil
            }

            if let idx = matchIndex {
                // Merge: existing timesheet + running timer_start from timer.timer
                let existing = result[idx]
                result[idx] = Timesheet(
                    id: existing.id,
                    accountId: existing.accountId,
                    name: existing.name,
                    projectName: existing.projectName,
                    source: existing.source,
                    unitAmount: existing.unitAmount,
                    timerStart: timer.timerStart,
                    date: existing.date
                )
            } else {
                // No matching timesheet yet — add as placeholder
                result.append(timer)
            }
        }
        return result
    }

    func startTimer(timesheet: Timesheet, client: OdooClient) async throws {
        // Must start via the source model so timer.timer gets the right res_model
        switch timesheet.source {
        case .task(let id, _):
            try await client.callMethod(
                model: "project.task", method: "action_timer_start", ids: [id])
        case .ticket(let id, _):
            try await client.callMethod(
                model: "helpdesk.ticket", method: "action_timer_start", ids: [id])
        case .standalone:
            try await client.callMethod(
                model: "account.analytic.line", method: "action_timer_start", ids: [timesheet.id])
        }
    }

    func stopTimer(timesheet: Timesheet, client: OdooClient) async throws -> Any {
        // Must stop via the source model — returns wizard action on Odoo 14-18
        switch timesheet.source {
        case .task(let id, _):
            return try await client.callMethodReturning(
                model: "project.task", method: "action_timer_stop", ids: [id])
        case .ticket(let id, _):
            return try await client.callMethodReturning(
                model: "helpdesk.ticket", method: "action_timer_stop", ids: [id])
        case .standalone:
            return try await client.callMethodReturning(
                model: "account.analytic.line", method: "action_timer_stop", ids: [timesheet.id])
        }
    }

    // MARK: - timer.timer queries

    private func fetchRunningTimerTimers(
        client: OdooClient, uid: Int, accountId: String
    ) async throws -> [Timesheet] {
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
                  let timerStart = Self.dateFormatter.date(from: record["timer_start"] as? String ?? "")
            else { continue }

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
                if let proj = taskRecords?.first?["project_id"] as? [Any],
                   proj.count >= 2, let projName = proj[1] as? String {
                    projectName = projName
                } else {
                    projectName = nil
                }
                source = .task(id: resId, name: name)
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
}
