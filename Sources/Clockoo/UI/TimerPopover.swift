import SwiftUI

/// The main popover view showing all timers grouped by account
struct TimerPopoverView: View {
    @ObservedObject var accountManager: AccountManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accountManager.accounts.isEmpty {
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
                            onStop: { accountManager.stopTimer(timesheet: timesheet) },
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
            Text("No active timers today")
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
    let onStop: () -> Void
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

            // Elapsed time
            Text(timesheet.elapsedFormatted)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(timesheet.state == .running ? .primary : .secondary)

            // Action buttons
            Button(action: onToggle) {
                Image(systemName: toggleIcon)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(toggleHelp)

            if timesheet.state == .running || timesheet.state == .paused {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Stop timer")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(timesheet.state == .stopped ? 0.6 : 1.0)
        .contextMenu {
            Button("Open in Odoo") { onOpen() }
        }
    }

    private var stateColor: Color {
        switch timesheet.state {
        case .running: return .green
        case .paused: return .orange
        case .stopped: return .gray.opacity(0.3)
        }
    }

    private var toggleIcon: String {
        switch timesheet.state {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        case .stopped: return "play.fill"
        }
    }

    private var toggleHelp: String {
        switch timesheet.state {
        case .running: return "Pause timer"
        case .paused: return "Resume timer"
        case .stopped: return "Start timer"
        }
    }
}
