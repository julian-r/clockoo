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
    private var popoverOpen = false
    private var lastTitle = ""
    private var lastIcon = ""
    private var lastTint: NSColor?
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
        // Don't resize while popover is open — it shifts the popover
        guard !popoverOpen else { return }

        var newTitle = ""
        var newIcon = "clock"
        var newTint: NSColor? = nil

        if let running = accountManager.runningTimesheet {
            isBlinking = false
            newIcon = "clock.fill"
            newTitle = " \(running.elapsedFormatted)"
            newTint = .systemGreen
        } else {
            if accountManager.blinkWhenIdle && !accountManager.accounts.isEmpty {
                isBlinking = true
                blinkPhase.toggle()
                if blinkPhase {
                    newIcon = "clock.fill"
                    newTint = .systemOrange
                } else {
                    newIcon = "clock"
                    newTint = nil
                }
            } else {
                isBlinking = false
            }
        }

        // Only update button properties when they actually change
        // Avoids unnecessary AppKit redraws that cause screen-jumping on multi-monitor
        if newTitle != lastTitle {
            button.title = newTitle
            lastTitle = newTitle
        }
        if newIcon != lastIcon {
            button.image = NSImage(
                systemSymbolName: newIcon,
                accessibilityDescription: "Clockoo"
            )
            lastIcon = newIcon
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
            popoverOpen = false
            // Restore variable length and update display
            statusItem.length = NSStatusItem.variableLength
            updateMenuBarDisplay()
        } else {
            accountManager.pollAll()
            // Freeze status item width while popover is open so it doesn't shift
            popoverOpen = true
            statusItem.length = button.frame.width
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
