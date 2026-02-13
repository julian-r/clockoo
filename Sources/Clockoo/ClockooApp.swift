import AppKit
import SwiftUI

/// Clockoo — lightweight macOS menu bar app for Odoo time tracking
@main
struct ClockooApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Menu bar only — no dock icon
        app.setActivationPolicy(.accessory)

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var accountManager: AccountManager?
    private var localAPIServer: LocalAPIServer?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure config directory exists
        ConfigLoader.ensureConfigDir()

        // Initialize account manager
        let manager = AccountManager()
        manager.loadAccounts()
        self.accountManager = manager

        // Settings window controller
        let settings = SettingsWindowController(accountManager: manager)
        self.settingsController = settings

        // Set up menu bar (pass settings controller for the ⚙ button)
        menuBarController = MenuBarController(accountManager: manager, settingsController: settings)

        // If no accounts or no API keys, open settings on first run
        let hasConfiguredAccount = manager.accounts.contains { account in
            KeychainHelper.getAPIKey(for: account.id) != nil
        }
        if manager.accounts.isEmpty || !hasConfiguredAccount {
            settings.showSettings()
        }

        // Start polling Odoo
        manager.startPolling()

        // Start local API server for Stream Deck integration
        let server = LocalAPIServer(accountManager: manager)
        server.start()
        self.localAPIServer = server

        // Update menu bar when timesheets change
        startMenuBarSync(manager: manager)

        print("[Clockoo] Started with \(manager.accounts.count) account(s)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        accountManager?.stopPolling()
        localAPIServer?.stop()
    }

    private func startMenuBarSync(manager: AccountManager) {
        // Poll the menu bar display update every 30s
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.menuBarController?.updateMenuBarDisplay()
            }
        }
    }
}
