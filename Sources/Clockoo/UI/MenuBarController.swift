import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon + text) and the popover
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var updateTimer: Timer?
    private let accountManager: AccountManager
    private let settingsController: SettingsWindowController

    init(accountManager: AccountManager, settingsController: SettingsWindowController) {
        self.accountManager = accountManager
        self.settingsController = settingsController
        setupStatusItem()
        setupPopover()
        startDisplayUpdates()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "clock",
                accessibilityDescription: "Clockoo"
            )
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        updateMenuBarDisplay()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 400)
        popover.behavior = .transient
        popover.animates = true
        let settingsAction = { [weak self] in
            self?.popover.performClose(nil)
            self?.settingsController.showSettings()
        }
        popover.contentViewController = NSHostingController(
            rootView: TimerPopoverView(
                accountManager: accountManager,
                onOpenSettings: settingsAction
            )
        )
    }

    private func startDisplayUpdates() {
        // Update menu bar text every 30 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMenuBarDisplay()
            }
        }

        // Also observe account manager changes
        // We'll update on a regular interval since we need live elapsed time
    }

    func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        if let running = accountManager.runningTimesheet {
            // Timer is running — show filled clock + elapsed time
            button.image = NSImage(
                systemSymbolName: "clock.fill",
                accessibilityDescription: "Timer running"
            )
            button.title = " \(running.elapsedFormatted)"

            // Tint the image green
            if let image = button.image {
                let tinted = image.copy() as! NSImage
                tinted.isTemplate = false
                // Use the template image with accent appearance
                button.image = NSImage(
                    systemSymbolName: "clock.fill",
                    accessibilityDescription: "Timer running"
                )
                button.contentTintColor = .systemGreen
            }
        } else {
            // No running timer — outline clock, no text
            button.image = NSImage(
                systemSymbolName: "clock",
                accessibilityDescription: "Clockoo"
            )
            button.title = ""
            button.contentTintColor = nil
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Refresh data when opening
            accountManager.pollAll()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Make popover the key window so it can receive events
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
