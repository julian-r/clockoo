import AppKit
import SwiftUI

/// Manages the settings window lifecycle (single instance)
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let accountManager: AccountManager

    init(accountManager: AccountManager) {
        self.accountManager = accountManager
    }

    func showSettings() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(accountManager: accountManager)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clockoo Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 650, height: 450))
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
