import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon + text) and the popover
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var updateTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkPhase = false
    private var isBlinking = false
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
        popover.behavior = .transient
        popover.animates = true
        let settingsAction = { [weak self] in
            self?.popover.performClose(nil)
            self?.settingsController.showSettings()
        }
        let hostingController = NSHostingController(
            rootView: TimerPopoverView(
                accountManager: accountManager,
                onOpenSettings: settingsAction
            )
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
    }

    private func startDisplayUpdates() {
        // Single timer drives both display updates and blinking
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMenuBarDisplay()
            }
        }
    }

    func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        if let running = accountManager.runningTimesheet {
            // Timer is running — show filled clock + elapsed time
            isBlinking = false
            button.image = NSImage(
                systemSymbolName: "clock.fill",
                accessibilityDescription: "Timer running"
            )
            button.title = " \(running.elapsedFormatted)"
            button.contentTintColor = .systemGreen
        } else {
            // No running timer
            button.title = ""

            if accountManager.blinkWhenIdle && !accountManager.accounts.isEmpty {
                // Blink: alternate every update cycle (1s)
                isBlinking = true
                blinkPhase.toggle()
                if blinkPhase {
                    button.image = NSImage(
                        systemSymbolName: "clock.fill",
                        accessibilityDescription: "Clockoo — no timer running"
                    )
                    button.contentTintColor = .systemOrange
                } else {
                    button.image = NSImage(
                        systemSymbolName: "clock",
                        accessibilityDescription: "Clockoo"
                    )
                    button.contentTintColor = nil
                }
            } else {
                isBlinking = false
                button.image = NSImage(
                    systemSymbolName: "clock",
                    accessibilityDescription: "Clockoo"
                )
                button.contentTintColor = nil
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            // Restore variable length when popover closes
            statusItem.length = NSStatusItem.variableLength
        } else {
            accountManager.pollAll()
            // Freeze status item width while popover is open so it doesn't shift
            statusItem.length = button.frame.width
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
