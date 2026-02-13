import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon + text) and the popover
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var updateTimer: Timer?
    private var blinkPhase = false
    private var isBlinking = false
    private var popoverOpen = false
    private var lastTitle = ""
    private var lastIconName = ""
    private var lastTint: NSColor?
    private let accountManager: AccountManager
    private let settingsController: SettingsWindowController

    // Cached images — avoids creating new NSImage instances every update
    private let iconClock: NSImage
    private let iconClockFill: NSImage

    init(accountManager: AccountManager, settingsController: SettingsWindowController) {
        self.accountManager = accountManager
        self.settingsController = settingsController

        // Pre-create and cache the two icon states
        iconClock = NSImage(systemSymbolName: "clock", accessibilityDescription: "Clockoo")!
        iconClockFill = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Clockoo")!

        super.init()

        setupStatusItem()
        setupPopover()
        startDisplayUpdates()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = iconClock
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
        popover.delegate = self
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
        guard !popoverOpen else { return }

        var newTitle = ""
        var newIconName = "clock"
        var newTint: NSColor? = nil

        if let running = accountManager.runningTimesheet {
            isBlinking = false
            newIconName = "clock.fill"
            newTitle = " \(running.elapsedFormatted)"
            newTint = .systemGreen
        } else {
            if accountManager.blinkWhenIdle && !accountManager.accounts.isEmpty {
                isBlinking = true
                blinkPhase.toggle()
                if blinkPhase {
                    newIconName = "clock.fill"
                    newTint = .systemOrange
                } else {
                    newIconName = "clock"
                    newTint = nil
                }
            } else {
                isBlinking = false
            }
        }

        // Only update button properties when they actually change.
        // Reuses cached NSImage instances to avoid AppKit redraws
        // that cause the status item to disappear from inactive screens.
        if newTitle != lastTitle {
            button.title = newTitle
            lastTitle = newTitle
        }
        if newIconName != lastIconName {
            button.image = newIconName == "clock.fill" ? iconClockFill : iconClock
            lastIconName = newIconName
        }
        if newTint != lastTint {
            button.contentTintColor = newTint
            lastTint = newTint
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            accountManager.pollAll()
            popoverOpen = true
            statusItem.length = button.frame.width
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popoverOpen = false
            statusItem.length = NSStatusItem.variableLength
            updateMenuBarDisplay()
        }
    }
}
