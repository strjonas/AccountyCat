//
//  ACApp.swift
//  AC
//
//  App entry point. Menu bar icon with two NSPopovers: a compact profile-control
//  surface for quick session changes, plus the full app popover for chat/settings.
//  Right-click keeps a minimal context menu.
//

import AppKit
import Combine
import SwiftUI

@main
struct ACApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController
    private var statusItem: NSStatusItem?
    private var windowCoordinator: WindowCoordinator?
    private var popover: NSPopover?
    private var profilePopover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var chipRefreshTimer: Timer?
    private var keyMonitor: Any?

    override init() {
        if NSClassFromString("XCTest") != nil {
            self.controller = AppController.makeForTesting(storageService: .temporary())
        } else {
            self.controller = AppController.shared
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTest") == nil else { return }
        NSApp.setActivationPolicy(.accessory)

        controller.bootstrap()

        // Close the popover whenever the user clicks outside of AC — .transient
        // alone doesn't fire for accessory apps when another app takes focus.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverOnResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        let wc = WindowCoordinator(controller: controller)
        self.windowCoordinator = wc

        let arm = ExecutiveArm(
            showNudge:   { [weak self] msg in self?.windowCoordinator?.showNudge(message: msg) },
            showOverlay: { [weak self] presentation in
                self?.windowCoordinator?.showOverlay(presentation: presentation)
            },
            hideOverlay: { [weak self] in     self?.windowCoordinator?.hideOverlay() },
            minimizeApp: { [weak self] bundleID in self?.minimizeApp(bundleIdentifier: bundleID) }
        )
        controller.attachExecutiveArm(arm)
        wc.showCompanion()

        // Allow the floating orb to open the popover when tapped — this is the
        // fallback entry point when the menu bar status item is hidden behind
        // macOS's overflow ( >> ) on small/crowded menu bars.
        wc.openPopoverFromOrb = { [weak self] in
            self?.togglePopoverFromOrb()
        }

        setUpStatusItem()
        bindMood()
        bindActiveProfile()
        startChipRefreshTimer()
        setUpKeyMonitor()

        // Show popover on first launch if setup isn't complete
        if controller.state.setupStatus != .ready {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openPopover()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.persistState()
        Task { @MainActor [weak self] in
            await self?.controller.shutdown()
        }
        return .terminateNow
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon(symbolName: "pawprint.fill", to: item)
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = item
    }

    private func applyIcon(symbolName: String, to item: NSStatusItem) {
        if let img = NSImage(systemSymbolName: symbolName,
                             accessibilityDescription: "AccountyCat") {
            img.isTemplate = true
            let size: CGFloat = 16
            img.size = NSSize(width: size, height: size)
            item.button?.image = img
        } else {
            item.button?.image = nil
        }
        item.button?.imagePosition = .imageLeft
        applyChipTitle(to: item)
    }

    /// Append the active profile's name + remaining time to the menu bar button.
    /// The default profile is shown too, so profile state is never hidden.
    private func applyChipTitle(to item: NSStatusItem) {
        guard let button = item.button else { return }
        let active = controller.state.activeProfile
        let unreadDot = controller.hasUnreadChatMessages ? " •" : ""

        if active.isDefault {
            button.title = " AC · \(active.name)\(unreadDot)"
            button.toolTip = controller.hasUnreadChatMessages
                ? "Active focus profile: \(active.name) — new message"
                : "Active focus profile: \(active.name)"
            return
        }
        let nameSegment = active.name
        let remainingSegment: String
        if let exp = active.expiresAt {
            let mins = Int(max(0, exp.timeIntervalSinceNow) / 60)
            if mins >= 60 {
                let hours = mins / 60
                let leftover = mins % 60
                remainingSegment = leftover == 0 ? " · \(hours)h" : " · \(hours)h\(leftover)m"
            } else {
                remainingSegment = " · \(max(1, mins))m"
            }
        } else {
            remainingSegment = ""
        }
        button.title = " AC · \(nameSegment)\(remainingSegment)\(unreadDot)"
        button.toolTip = controller.hasUnreadChatMessages
            ? "Active focus profile: \(nameSegment) — new message"
            : "Active focus profile: \(nameSegment)"
    }

    /// Refresh the chip whenever the active profile id changes (also covers expiry-driven
    /// switches back to default in BrainService.tick) or unread-state changes.
    private func bindActiveProfile() {
        controller.$state
            .map { $0.activeProfileID }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let item = self.statusItem else { return }
                self.applyChipTitle(to: item)
            }
            .store(in: &cancellables)
        controller.$hasUnreadChatMessages
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let item = self.statusItem else { return }
                self.applyChipTitle(to: item)
            }
            .store(in: &cancellables)
    }

    /// Refresh the chip title every 30 s so the remaining-time countdown stays current.
    private func startChipRefreshTimer() {
        chipRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let item = self.statusItem else { return }
            self.applyChipTitle(to: item)
        }
        chipRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Keyboard shortcuts

    private func setUpKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmd = flags == .command

            // ── Escape: context-aware dismiss ──
            if event.keyCode == 53 {
                return self.handleEscape(event)
            }

            // ── Cmd+Q: quit ──
            if isCmd && event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }

            // ── Cmd+P: pause/resume ──
            if isCmd && event.charactersIgnoringModifiers == "p" {
                self.controller.togglePause()
                return nil
            }

            // ── Cmd+M: toggle sound ──
            if isCmd && event.charactersIgnoringModifiers == "m" {
                let current = UserDefaults.standard.bool(forKey: "acSoundEnabled")
                UserDefaults.standard.set(!current, forKey: "acSoundEnabled")
                return nil
            }

            // ── Cmd+V: toggle vision ──
            if isCmd && event.charactersIgnoringModifiers == "v" {
                self.controller.updateVisionEnabled(!self.controller.visionEnabled)
                return nil
            }

            // ── Cmd+K: focus chat input ──
            if isCmd && event.charactersIgnoringModifiers == "k" {
                NotificationCenter.default.post(name: .acFocusChatInput, object: nil)
                return nil
            }

            // ── Cmd+,: settings ──
            if event.keyCode == 43 && flags == .command {
                NotificationCenter.default.post(name: .acOpenSettings, object: nil)
                return nil
            }

            return event
        }
    }

    /// Context-aware Escape:  overlay → sheet → ContextBar → popover → profile popover
    private func handleEscape(_ event: NSEvent) -> NSEvent? {
        // 1. Overlay — highest priority
        if let wc = windowCoordinator, wc.isOverlayVisible {
            wc.hideOverlay()
            return nil
        }

        // 2. Sheet — tell SwiftUI to dismiss it, then stop
        if let p = popover, p.isShown,
           let contentVC = p.contentViewController,
           contentVC.presentedViewControllers?.isEmpty == false {
            NotificationCenter.default.post(name: .acDismissSheet, object: nil)
            return nil
        }

        // 3. ContextBar expanded — collapse it
        if UserDefaults.standard.bool(forKey: "acContextBarExpanded") {
            UserDefaults.standard.set(false, forKey: "acContextBarExpanded")
            return nil
        }

        // 4. Popover
        if let p = popover, p.isShown {
            p.performClose(nil)
            return nil
        }

        // 5. Profile popover
        if let p = profilePopover, p.isShown {
            p.performClose(nil)
            return nil
        }

        return event
    }

    // MARK: - Mood-reactive icon

    private func bindMood() {
        controller.$companionMood
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mood in
                guard let self, let item = self.statusItem else { return }
                let symbol: String
                switch mood {
                case .nudging:  symbol = "bubble.left.fill"
                case .escalated: symbol = "exclamationmark.bubble.fill"
                case .escalatedHard: symbol = "xmark.shield.fill"
                case .paused:   symbol = "pause.circle.fill"
                case .setup:    symbol = "gearshape.fill"
                default:        symbol = "pawprint.fill"
                }
                self.applyIcon(symbolName: symbol, to: item)

                // Close the popover when a nudge fires so the speech bubble and
                // settings panel don't overlap. The NSPopover instance is reused,
                // so SwiftUI @State (draft text, scroll position, etc.) is preserved.
                if mood == .nudging, let p = self.popover, p.isShown {
                    p.performClose(nil)
                }
                if mood == .nudging, let p = self.profilePopover, p.isShown {
                    p.performClose(nil)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Click handling

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            profilePopover?.performClose(nil)
            showContextMenu(for: sender)
        } else {
            toggleStatusPopover(relativeTo: sender)
        }
    }

    // MARK: - Main popover

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        let p = popover ?? makePopover()
        popover = p
        profilePopover?.performClose(nil)
        guard !p.isShown else { return }
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        controller.markAllChatMessagesRead()
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if let p = popover, p.isShown {
            p.performClose(nil)
        } else {
            let p = popover ?? makePopover()
            popover = p
            profilePopover?.performClose(nil)
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            controller.markAllChatMessagesRead()
        }
    }

    /// Opens (or closes) the popover anchored directly beside the companion orb.
    /// Detects which half of the screen the orb is in and opens on the near side
    /// so the popover never jumps far from the cat. Falls back to the status bar
    /// button when the panel is unavailable (e.g. before first show).
    func togglePopoverFromOrb() {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        let p = popover ?? makePopover()
        popover = p
        profilePopover?.performClose(nil)

        if let wc = windowCoordinator,
           let panel = wc.companionPanel,
           let contentView = panel.contentView {
            // Anchor to a rect near the orb (bottom of the panel content view)
            // and choose the edge based on whether the orb is in the upper or
            // lower half of the screen, so the popover always opens toward centre.
            let anchorRect = wc.orbAnchorRect(in: contentView)
            let edge: NSRectEdge = wc.orbIsInBottomHalf ? .maxY : .minY
            p.show(relativeTo: anchorRect, of: contentView, preferredEdge: edge)
        } else if let button = statusItem?.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.markAllChatMessagesRead()
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.contentSize = NSSize(width: ACD.popoverWidth, height: 460)
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(
            rootView: ChatPopoverView()
                .environmentObject(controller)
        )
        controller.dismissPopover = { [weak p] in
            p?.performClose(nil)
        }
        controller.resizePopover = { [weak p] size in
            guard let p else { return }
            p.contentSize = size
        }
        return p
    }

    // MARK: - Quick profile popover

    private func toggleStatusPopover(relativeTo button: NSStatusBarButton) {
        if controller.state.setupStatus != .ready {
            togglePopover(relativeTo: button)
            return
        }

        if let quick = profilePopover, quick.isShown {
            quick.performClose(nil)
            return
        }

        let quick = profilePopover ?? makeProfilePopover()
        profilePopover = quick
        popover?.performClose(nil)
        quick.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        controller.markAllChatMessagesRead()
    }

    private func makeProfilePopover() -> NSPopover {
        let p = NSPopover()
        p.contentSize = NSSize(width: 336, height: 430)
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(
            rootView: ProfileQuickPopoverView(showOpenAppButton: true)
                .environmentObject(controller)
        )
        controller.dismissProfilePopover = { [weak p] in
            p?.performClose(nil)
        }
        controller.openMainPopover = { [weak self, weak p] in
            p?.performClose(nil)
            self?.openPopover()
        }
        return p
    }

    // MARK: - Right-click context menu (minimal — full controls live in the popover)

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open AccountyCat",
                                  action: #selector(openMainPopoverFromMenu),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let pauseTitle = controller.state.isPaused ? "Resume Monitoring" : "Pause Monitoring"
        let pauseItem = NSMenuItem(title: pauseTitle,
                                   action: #selector(togglePause),
                                   keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AccountyCat",
                                  action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func togglePause()  { controller.togglePause() }
    @objc private func openMainPopoverFromMenu() { openPopover() }
    @objc private func quitApp()      { NSApp.terminate(nil) }

    @objc private func closePopoverOnResignActive() {
        if let p = popover, p.isShown {
            p.performClose(nil)
        }
        if let p = profilePopover, p.isShown {
            p.performClose(nil)
        }
    }

    private func minimizeApp(bundleIdentifier: String?) {
        guard let bundleID = bundleIdentifier else { return }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) {
            app.hide()
        }
    }
}
