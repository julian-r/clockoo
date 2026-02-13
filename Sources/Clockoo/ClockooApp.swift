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

        // Set up Edit menu so Cmd+V/C/X/A work in text fields
        setupMainMenu()

        app.run()
    }

    /// Accessory apps don't get a default menu bar — we need to create one
    /// with an Edit menu for paste/copy/cut/select-all to work in text fields.
    private static func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clockoo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clockoo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cmd+C, Cmd+V, Cmd+X, Cmd+A)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
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

        // Connect to Odoo accounts (auto-detects API version) and start polling
        manager.connectAndStartPolling()

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
