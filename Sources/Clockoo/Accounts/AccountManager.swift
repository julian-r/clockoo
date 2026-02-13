import Foundation

/// Manages multiple Odoo accounts, each with its own client and timer service
@MainActor
final class AccountManager: ObservableObject {
    @Published var accounts: [AccountConfig] = []
    @Published var timesheetsByAccount: [String: [Timesheet]] = [:]
    @Published var errors: [String: String] = [:]

    private var timerServices: [String: OdooTimerService] = [:]
    private var pollTimers: [String: Timer] = [:]
    private var displayTimer: Timer?

    /// The poll interval in seconds
    var pollInterval: TimeInterval = 60

    /// All timesheets across all accounts, sorted: running first, then paused, then stopped
    var allTimesheets: [Timesheet] {
        timesheetsByAccount.values.flatMap { $0 }.sorted { a, b in
            let order: (TimerState) -> Int = { state in
                switch state {
                case .running: return 0
                case .paused: return 1
                case .stopped: return 2
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
            accounts = try ConfigLoader.load()
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

        // Update display every 30s for live elapsed time
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
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
        guard let service = timerServices[accountId] else { return }
        Task {
            do {
                let timesheets = try await service.fetchActiveTimesheets()
                await MainActor.run {
                    self.timesheetsByAccount[accountId] = timesheets
                    self.errors.removeValue(forKey: accountId)
                }
            } catch {
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

    // MARK: - Timer Actions

    func startTimer(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        Task {
            try await service.startTimer(timesheetId: timesheet.id)
            pollNow(accountId: timesheet.accountId)
        }
    }

    func stopTimer(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        Task {
            try await service.stopTimer(timesheetId: timesheet.id)
            pollNow(accountId: timesheet.accountId)
        }
    }

    func pauseTimer(timesheet: Timesheet) {
        guard let service = timerServices[timesheet.accountId] else { return }
        Task {
            try await service.pauseTimer(timesheetId: timesheet.id)
            pollNow(accountId: timesheet.accountId)
        }
    }

    func toggleTimer(timesheet: Timesheet) {
        switch timesheet.state {
        case .running:
            pauseTimer(timesheet: timesheet)
        case .paused:
            startTimer(timesheet: timesheet)
        case .stopped:
            startTimer(timesheet: timesheet)
        }
    }

    /// Get the base URL for an account (for opening web URLs)
    func baseURL(for accountId: String) -> String? {
        accounts.first { $0.id == accountId }?.url
    }
}
