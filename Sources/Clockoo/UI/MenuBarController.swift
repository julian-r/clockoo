import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon + text) and the popover
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var updateTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkVisible = true
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
            stopBlinking()
            button.image = NSImage(
                systemSymbolName: "clock.fill",
                accessibilityDescription: "Timer running"
            )
            button.title = " \(running.elapsedFormatted)"
            button.contentTintColor = .systemGreen
            button.appearsDisabled = false
        } else {
            // No running timer
            button.title = ""
            button.contentTintColor = nil

            if accountManager.blinkWhenIdle && !accountManager.accounts.isEmpty {
                startBlinking()
            } else {
                stopBlinking()
                button.image = NSImage(
                    systemSymbolName: "clock",
                    accessibilityDescription: "Clockoo"
                )
                button.appearsDisabled = false
            }
        }
    }

    // MARK: - Blink

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        blinkVisible = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.blinkVisible.toggle()
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: self.blinkVisible ? "clock" : "clock.fill",
                    accessibilityDescription: "Clockoo — no timer running"
                )
                self.statusItem.button?.contentTintColor = self.blinkVisible ? nil : .systemOrange
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkVisible = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            accountManager.pollAll()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
