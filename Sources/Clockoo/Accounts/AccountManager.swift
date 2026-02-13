import Foundation

/// Manages multiple Odoo accounts, each with its own client and timer service
@MainActor
final class AccountManager: ObservableObject {
    @Published var accounts: [AccountConfig] = []
    @Published var timesheetsByAccount: [String: [Timesheet]] = [:]
    @Published var errors: [String: String] = [:]
    @Published var blinkWhenIdle: Bool = false

    private var timerServices: [String: OdooTimerService] = [:]
    private var pollTimers: [String: Timer] = [:]
    private var displayTimer: Timer?

    /// The poll interval in seconds
    var pollInterval: TimeInterval = 5

    /// All timesheets across all accounts, sorted: running first, then paused, then stopped
    var allTimesheets: [Timesheet] {
        timesheetsByAccount.values.flatMap { $0 }.sorted { a, b in
            let order: (TimerState) -> Int = { state in
                switch state {
                case .running: return 0
                case .stopped: return 1
                }
            }
            return order(a.state) < order(b.state)
        }
    }

    /// Whether any timer is currently running across all accounts
    var hasRunningTimer: Bool {
        allTimesheets.contains { $0.state == .running }
    }

    /// The currently running timesheet (if any)
    var runningTimesheet: Timesheet? {
        allTimesheets.first { $0.state == .running }
    }

    func loadAccounts() {
        do {
            let config = try ConfigLoader.loadConfig()
            accounts = config.accounts
            blinkWhenIdle = config.blinkWhenIdle
            for account in accounts {
                setupService(for: account)
            }
        } catch {
            print("Failed to load accounts: \(error)")
        }
    }

    private func setupService(for account: AccountConfig) {
        guard let apiKey = KeychainHelper.getAPIKey(for: account.id) else {
            errors[account.id] = "No API key in Keychain for '\(account.id)'. Add it via Settings."
            return
        }

        let client = OdooJSONRPCClient(
            url: account.url,
            database: account.database,
            username: account.username,
            apiKey: apiKey,
            apiVersion: account.apiVersion
        )
        let service = OdooTimerService(client: client, accountId: account.id)
        timerServices[account.id] = service
        errors.removeValue(forKey: account.id)
    }

    func startPolling() {
        // Poll each account independently
        for account in accounts {
            pollNow(accountId: account.id)
            let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
                [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.pollNow(accountId: account.id)
                }
            }
            pollTimers[account.id] = timer
        }

        // Trigger SwiftUI updates every second for live elapsed time in popover
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    func stopPolling() {
        for timer in pollTimers.values { timer.invalidate() }
        pollTimers.removeAll()
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func pollNow(accountId: String) {
        guard let service = timerServices[accountId] else {
            print("[Poll:\(accountId)] No service — missing API key?")
            return
        }
        Task {
            do {
                let timesheets = try await service.fetchTodayTimesheets()
                let running = timesheets.filter { $0.state == .running }.count
                let stopped = timesheets.filter { $0.state == .stopped }.count
                print("[Poll:\(accountId)] \(timesheets.count) timesheets (running=\(running) stopped=\(stopped))")
                await MainActor.run {
                    self.timesheetsByAccount[accountId] = timesheets
                    self.errors.removeValue(forKey: accountId)
                }
            } catch {
                print("[Poll:\(accountId)] Error: \(error)")
                await MainActor.run {
                    self.errors[accountId] = error.localizedDescription
                }
            }
        }
    }

    func pollAll() {
        for account in accounts {
            pollNow(accountId: account.id)
        }
    }

    // MARK: - Timer Actions (with optimistic updates)

    func startTimer(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        // Optimistic: mark as running immediately
        optimisticUpdate(timesheet: timesheet, running: true)
        Task {
            do {
                try await service.startTimer(timesheetId: timesheet.id)
            } catch {
                print("[Timer] Start failed: \(error)")
            }
            pollNow(accountId: timesheet.accountId)
        }
    }

    func stopTimer(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        // Optimistic: mark as stopped immediately
        optimisticUpdate(timesheet: timesheet, running: false)
        Task {
            do {
                try await service.stopTimer(timesheetId: timesheet.id)
            } catch {
                print("[Timer] Stop failed: \(error)")
            }
            pollNow(accountId: timesheet.accountId)
        }
    }

    func deleteTimesheet(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        // Optimistic: remove from local state immediately
        if var timesheets = timesheetsByAccount[timesheet.accountId] {
            timesheets.removeAll { $0.id == timesheet.id }
            timesheetsByAccount[timesheet.accountId] = timesheets
        }
        Task {
            do {
                try await service.deleteTimesheet(timesheetId: timesheet.id)
            } catch {
                print("[Timer] Delete failed: \(error)")
            }
            pollNow(accountId: timesheet.accountId)
        }
    }

    func toggleTimer(timesheet: Timesheet) {
        switch timesheet.state {
        case .running:
            stopTimer(timesheet: timesheet)
        case .stopped:
            startTimer(timesheet: timesheet)
        }
    }

    /// Immediately update local state for responsive UX.
    /// The next poll will correct with the real server state.
    private func optimisticUpdate(timesheet: Timesheet, running: Bool) {
        guard var timesheets = timesheetsByAccount[timesheet.accountId],
              let index = timesheets.firstIndex(where: { $0.id == timesheet.id })
        else { return }

        let updated = Timesheet(
            id: timesheet.id,
            accountId: timesheet.accountId,
            name: timesheet.name,
            projectName: timesheet.projectName,
            source: timesheet.source,
            unitAmount: timesheet.unitAmount,
            timerStart: running ? Date() : nil,
            date: timesheet.date
        )

        // If starting a timer, stop any other running timers (Odoo does this automatically)
        if running {
            for i in timesheets.indices {
                if timesheets[i].state == .running && timesheets[i].id != timesheet.id {
                    timesheets[i] = Timesheet(
                        id: timesheets[i].id,
                        accountId: timesheets[i].accountId,
                        name: timesheets[i].name,
                        projectName: timesheets[i].projectName,
                        source: timesheets[i].source,
                        unitAmount: timesheets[i].unitAmount,
                        timerStart: nil,
                        date: timesheets[i].date
                    )
                }
            }
        }

        timesheets[index] = updated
        timesheetsByAccount[timesheet.accountId] = timesheets
    }

    /// Get the base URL for an account (for opening web URLs)
    func baseURL(for accountId: String) -> String? {
        accounts.first { $0.id == accountId }?.url
    }
}
