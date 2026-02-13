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
        } catch {
            print("Failed to load accounts: \(error)")
        }
    }

    /// Connect to all accounts (auto-detects API version), then start polling.
    /// Call this after loadAccounts().
    func connectAndStartPolling() {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask { [self] in
                        await self.setupService(for: account)
                    }
                }
            }
            // All services are ready — now start polling
            startPolling()
        }
    }

    private func setupService(for account: AccountConfig) async {
        guard let apiKey = KeychainHelper.getAPIKey(for: account.id) else {
            await MainActor.run {
                errors[account.id] = "No API key in Keychain for '\(account.id)'. Add it via Settings."
            }
            return
        }

        let conn = await makeOdooConnection(
            url: account.url,
            database: account.database,
            username: account.username,
            apiKey: apiKey
        )
        let service = OdooTimerService(client: conn.client, backend: conn.backend, accountId: account.id)
        await MainActor.run {
            timerServices[account.id] = service
            errors.removeValue(forKey: account.id)
        }
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
                try await service.startTimer(timesheet: timesheet)
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
                try await service.stopTimer(timesheet: timesheet)
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

    // MARK: - Search

    /// Search result with account context
    struct AccountSearchResult: Identifiable {
        let id: String  // unique key: "accountId-kind-sourceId"
        let accountId: String
        let result: OdooTimerService.SearchResult
    }

    /// Search across all accounts in parallel
    func search(query: String) async -> [String: [AccountSearchResult]] {
        var allResults: [String: [AccountSearchResult]] = [:]

        await withTaskGroup(of: (String, [AccountSearchResult]).self) { group in
            for account in accounts {
                guard let service = timerServices[account.id] else { continue }
                group.addTask {
                    var results: [AccountSearchResult] = []

                    // Search tasks
                    if let tasks = try? await service.searchTasks(query: query) {
                        results += tasks.map { r in
                            AccountSearchResult(
                                id: "\(account.id)-task-\(r.id)",
                                accountId: account.id,
                                result: r
                            )
                        }
                    }

                    // Search tickets (if helpdesk available)
                    if let tickets = try? await service.searchTickets(query: query) {
                        results += tickets.map { r in
                            AccountSearchResult(
                                id: "\(account.id)-ticket-\(r.id)",
                                accountId: account.id,
                                result: r
                            )
                        }
                    }

                    // Search recent timesheets
                    if let recent = try? await service.searchRecentTimesheets(query: query) {
                        results += recent.map { r in
                            AccountSearchResult(
                                id: "\(account.id)-recent-\(r.id)",
                                accountId: account.id,
                                result: r
                            )
                        }
                    }

                    return (account.id, results)
                }
            }
            for await (accountId, results) in group {
                allResults[accountId] = results
            }
        }

        return allResults
    }

    /// Start a timer on a search result (with optimistic update)
    func startTimerOnSearchResult(_ result: AccountSearchResult) {
        guard let service = timerServices[result.accountId] else { return }

        // Optimistic: stop any other running timers and insert a placeholder
        let r = result.result
        let placeholderId = -(r.id)  // negative ID as placeholder

        let source: TimerSource
        switch r.kind {
        case .task: source = .task(id: r.id, name: r.name)
        case .ticket: source = .ticket(id: r.id, name: r.name)
        case .recentTimesheet:
            // For recent timesheets, reuse existing source info
            source = .task(id: r.id, name: r.name)
        }

        let placeholder = Timesheet(
            id: r.kind == .recentTimesheet ? (r.timesheetId ?? placeholderId) : placeholderId,
            accountId: result.accountId,
            name: r.name,
            projectName: r.projectName,
            source: source,
            unitAmount: 0,
            timerStart: Date(),
            date: Self.todayString
        )

        // Stop other running timers optimistically
        for accountId in timesheetsByAccount.keys {
            if var timesheets = timesheetsByAccount[accountId] {
                for i in timesheets.indices {
                    if timesheets[i].state == .running {
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
                timesheetsByAccount[accountId] = timesheets
            }
        }

        // Insert placeholder (or update existing for recent timesheets)
        var timesheets = timesheetsByAccount[result.accountId] ?? []
        if let existingIdx = timesheets.firstIndex(where: { $0.id == placeholder.id }) {
            timesheets[existingIdx] = placeholder
        } else {
            timesheets.insert(placeholder, at: 0)
        }
        timesheetsByAccount[result.accountId] = timesheets

        // Fire API call, then poll to get real data
        Task {
            do {
                switch r.kind {
                case .task:
                    try await service.startTimerOnTask(taskId: r.id)
                case .ticket:
                    try await service.startTimerOnTicket(ticketId: r.id)
                case .recentTimesheet:
                    // Recent timesheets already have a source, start via the placeholder
                    try await service.startTimer(timesheet: placeholder)
                }
            } catch {
                print("[Search] Start timer failed: \(error)")
            }
            pollNow(accountId: result.accountId)
        }
    }

    private static var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    /// Get the base URL for an account (for opening web URLs)
    func baseURL(for accountId: String) -> String? {
        accounts.first { $0.id == accountId }?.url
    }
}
