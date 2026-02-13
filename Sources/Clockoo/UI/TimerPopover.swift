import SwiftUI

/// The main popover view showing all timers grouped by account
struct TimerPopoverView: View {
    @ObservedObject var accountManager: AccountManager
    var onOpenSettings: (() -> Void)?

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [String: [AccountManager.AccountSearchResult]] = [:]
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            if !accountManager.accounts.isEmpty {
                searchBar
                    .padding(.bottom, 8)
            }

            if !searchText.isEmpty || isSearching {
                searchResultsView
            } else if accountManager.accounts.isEmpty {
                noAccountsView
            } else if accountManager.allTimesheets.isEmpty && accountManager.errors.isEmpty {
                noTimersView
            } else {
                timerListView
            }

            Divider()
                .padding(.vertical, 4)

            bottomBar
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search tasks, tickets…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .onChange(of: searchText) { _, newValue in
                    performSearch(query: newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = [:]
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            if isSearching {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        if query.isEmpty {
            searchResults = [:]
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = await accountManager.search(query: query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let allResults = flattenedResults
            if allResults.isEmpty && !isSearching {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No results")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                let showHeaders = accountManager.accounts.count > 1
                let grouped = groupedResults(allResults)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(grouped, id: \.header) { section in
                            if showHeaders {
                                Text(section.header)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in
                                SearchResultRow(item: item) {
                                    accountManager.startTimerOnSearchResult(item)
                                    searchText = ""
                                    searchResults = [:]
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
        }
    }

    private var flattenedResults: [AccountManager.AccountSearchResult] {
        searchResults.values.flatMap { $0 }
    }

    private struct SearchSection: Identifiable {
        let header: String
        let items: [AccountManager.AccountSearchResult]
        var id: String { header }
    }

    private func groupedResults(_ results: [AccountManager.AccountSearchResult]) -> [SearchSection] {
        var sections: [SearchSection] = []
        // Group by kind across accounts
        let tasks = results.filter { $0.result.kind == .task }
        let tickets = results.filter { $0.result.kind == .ticket }
        let recent = results.filter { $0.result.kind == .recentTimesheet }

        if !tasks.isEmpty { sections.append(SearchSection(header: "Tasks", items: tasks)) }
        if !tickets.isEmpty { sections.append(SearchSection(header: "Tickets", items: tickets)) }
        if !recent.isEmpty { sections.append(SearchSection(header: "Recent", items: recent)) }
        return sections
    }

    // MARK: - Timer List

    private var timerListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let showHeaders = accountManager.accounts.count > 1

            ForEach(accountManager.accounts) { account in
                let timesheets = accountManager.timesheetsByAccount[account.id] ?? []
                let error = accountManager.errors[account.id]

                if showHeaders {
                    accountHeader(account: account)
                }

                if let error {
                    errorRow(error)
                } else if timesheets.isEmpty {
                    Text("No active timers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.leading, showHeaders ? 8 : 0)
                } else {
                    ForEach(timesheets) { timesheet in
                        TimerRow(
                            timesheet: timesheet,
                            onToggle: { accountManager.toggleTimer(timesheet: timesheet) },
                            onDelete: { accountManager.deleteTimesheet(timesheet: timesheet) },
                            onOpen: { openInBrowser(timesheet: timesheet) }
                        )
                    }
                }
            }
        }
    }

    private func accountHeader(account: AccountConfig) -> some View {
        Text(account.label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func errorRow(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty States

    private var noAccountsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No accounts configured")
                .font(.headline)
            Text("Edit ~/.config/clockoo/accounts.json")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var noTimersView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No timesheets today")
                .font(.headline)
            Text("Start a timer in Odoo to see it here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button {
                accountManager.pollAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                Text("Refresh")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Spacer()

            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                Text("Settings")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                Text("Quit")
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }

    // MARK: - Actions

    private func openInBrowser(timesheet: Timesheet) {
        guard let baseURL = accountManager.baseURL(for: timesheet.accountId),
              let url = timesheet.webURL(baseURL: baseURL)
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Timer Row

struct TimerRow: View {
    let timesheet: Timesheet
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // State indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(stateColor)
                .frame(width: 3, height: 32)

            // Source icon + name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(timesheet.source.icon)
                        .font(.caption)
                    Text(timesheet.displayLabel.dropFirst(2))  // Remove the emoji we already show
                        .font(.system(.body, design: .default))
                        .fontWeight(timesheet.state == .running ? .medium : .regular)
                        .lineLimit(1)
                }

                if let project = timesheet.projectName {
                    Text(project)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Elapsed time — fixed width to prevent layout shifts
            Text(timesheet.elapsedFormatted)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(timesheet.state == .running ? .primary : .secondary)
                .frame(minWidth: 44, alignment: .trailing)

            // Action buttons — fixed frames to prevent layout shifts
            Button(action: onToggle) {
                Image(systemName: toggleIcon)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(toggleHelp)
            .frame(width: 24, height: 24)

            if timesheet.hasWebLink {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right.square")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in Odoo")
                .frame(width: 24, height: 24)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete entry")
            .frame(width: 24, height: 24)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(timesheet.state == .stopped ? 0.6 : 1.0)
        .contextMenu {
            Button("Open in Odoo") { onOpen() }
            Divider()
            Button("Delete Entry", role: .destructive) { onDelete() }
        }
    }

    private var stateColor: Color {
        switch timesheet.state {
        case .running: return .green
        case .stopped: return .gray.opacity(0.3)
        }
    }

    private var toggleIcon: String {
        switch timesheet.state {
        case .running: return "stop.fill"
        case .stopped: return "play.fill"
        }
    }

    private var toggleHelp: String {
        switch timesheet.state {
        case .running: return "Stop timer"
        case .stopped: return "Start timer"
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let item: AccountManager.AccountSearchResult
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kindIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.result.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)

                if let project = item.result.projectName {
                    Text(project)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Start timer")
            .frame(width: 24, height: 24)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var kindIcon: String {
        switch item.result.kind {
        case .task: return "hammer"
        case .ticket: return "ticket"
        case .recentTimesheet: return "clock.arrow.circlepath"
        }
    }
}
