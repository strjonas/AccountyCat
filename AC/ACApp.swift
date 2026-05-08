//
//  ACApp.swift
//  AC
//
//  App entry point. Menu bar text item with a single NSPopover for chat/settings.
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller: AppController
    private var statusItem: NSStatusItem?
    private var windowCoordinator: WindowCoordinator?
    private var popover: NSPopover?
    private var orbPopoverAnchorWindow: NSWindow?
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

        // Re-open the popover when returning to AC during onboarding
        // (e.g. after granting permissions in System Settings).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reopenPopoverIfOnboarding),
            name: NSApplication.didBecomeActiveNotification,
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
            minimizeApp: { [weak self] bundleID in self?.minimizeApp(bundleIdentifier: bundleID) },
            hideCompanion: { [weak self] in self?.windowCoordinator?.hideCompanion() },
            showCompanion: { [weak self] in self?.windowCoordinator?.showCompanion() }
        )
        controller.attachExecutiveArm(arm)

        // Allow the floating orb to open the popover when tapped — this is the
        // fallback entry point when the menu bar status item is hidden behind
        // macOS's overflow ( >> ) on small/crowded menu bars.
        wc.openPopoverFromOrb = { [weak self] in
            self?.togglePopoverFromOrb()
        }
        wc.statusItemButtonFrameProvider = { [weak self] in
            guard let button = self?.statusItem?.button,
                  let window = button.window else { return .zero }
            let localRect = button.bounds
            let windowRect = button.convert(localRect, to: nil)
            return window.convertToScreen(windowRect)
        }

        setUpStatusItem()
        bindMood()
        bindActiveProfile()
        bindOnboardingState()
        bindDisplayMode()
        startChipRefreshTimer()
        setUpKeyMonitor()

        applyDisplayMode(controller.state.displayMode)
        wc.playEntranceAnimation()

        if !controller.hasCompletedOnboardingWizard {
            // During onboarding anchor the popover to the companion orb so it
            // appears right beside the cat instead of far away at the menu bar.
            togglePopoverFromOrb()
        } else if controller.state.setupStatus != .ready {
            // Show popover on first launch if setup isn't complete.
            // Delay until the entrance animation finishes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
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
        applyChipTitle(to: item)
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = item
    }

    /// Refresh the chip based on the selected status bar style.
    private func applyChipTitle(to item: NSStatusItem) {
        guard let button = item.button else { return }
        let style = controller.state.statusBarStyle
        let unreadDot = controller.hasUnreadChatMessages ? " •" : ""

        switch style {
        case .icon:
            let img = CatView.menuBarTemplateImage(
                size: 18,
                character: controller.state.character,
                skin: controller.state.selectedSkin,
                expression: .neutral
            )
            button.image = img
            button.title = ""

        case .ac:
            button.image = nil
            button.title = "AC\(unreadDot)"

        case .profile:
            button.image = nil
            let active = controller.state.activeProfile
            if active.isDefault {
                button.title = "\(active.name)\(unreadDot)"
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
            button.title = "\(nameSegment)\(remainingSegment)\(unreadDot)"
            button.toolTip = controller.hasUnreadChatMessages
                ? "Active focus profile: \(nameSegment) — new message"
                : "Active focus profile: \(nameSegment)"
        }
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
        controller.$state
            .map(\.statusBarStyle)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let item = self.statusItem else { return }
                self.applyChipTitle(to: item)
            }
            .store(in: &cancellables)
        controller.$state
            .map { "\($0.character.rawValue)-\($0.selectedSkin.rawValue)" }
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
            // Let paste work when a text field is focused (chat composer, settings, etc.)
            if isCmd && event.charactersIgnoringModifiers == "v" {
                if self.keyWindowHasTextInputFocus() {
                    return event
                }
                self.controller.updateVisionEnabled(!self.controller.visionEnabled)
                return nil
            }

            // ── Cmd+K: focus chat input (panel-only) ──
            let panelIsOpen = self.popover?.isShown == true
            if isCmd && event.charactersIgnoringModifiers == "k" && panelIsOpen {
                NotificationCenter.default.post(name: .acFocusChatInput, object: nil)
                return nil
            }

            // ── Cmd+,: settings (panel-only) ──
            if event.keyCode == 43 && flags == .command && panelIsOpen {
                NotificationCenter.default.post(name: .acOpenSettings, object: nil)
                return nil
            }

            return event
        }
    }

    private func keyWindowHasTextInputFocus() -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        let responder = keyWindow.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    /// Context-aware Escape:  overlay → sheet → popover → profile popover
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

        // 3. Popover
        if let p = popover, p.isShown {
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
                guard let self else { return }

                // Close the popover when a nudge fires so the speech bubble and
                // settings panel don't overlap. The NSPopover instance is reused,
                // so SwiftUI @State (draft text, scroll position, etc.) is preserved.
                if mood == .nudging, let p = self.popover, p.isShown {
                    p.performClose(nil)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Onboarding / popover root

    private func bindOnboardingState() {
        controller.$hasCompletedOnboardingWizard
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completed in
                guard let self, let p = self.popover else { return }
                let height: CGFloat = completed ? 460 : 540
                p.contentSize = NSSize(width: ACD.popoverWidth, height: height)
            }
            .store(in: &cancellables)
    }

    // MARK: - Display mode

    private func bindDisplayMode() {
        controller.$state
            .map(\.displayMode)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applyDisplayMode(mode)
            }
            .store(in: &cancellables)
    }

    private func applyDisplayMode(_ mode: ACDisplayMode) {
        // Orb
        if mode.showsOrb {
            windowCoordinator?.showCompanion()
        } else {
            windowCoordinator?.hideCompanion()
        }

        // Dismiss status bar nudge if switching away from menuBar
        if !mode.showsMenuBar {
            windowCoordinator?.dismissStatusBarNudgePanel()
        }

        // Menu bar status item
        if mode.showsMenuBar {
            if statusItem == nil { setUpStatusItem() }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    @objc private func reopenPopoverIfOnboarding() {
        guard !controller.hasCompletedOnboardingWizard else { return }
        togglePopoverFromOrb()
    }

    // MARK: - Click handling

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    // MARK: - Main popover

    private func openPopover() {
        let p = popover ?? makePopover()
        popover = p
        p.behavior = controller.hasCompletedOnboardingWizard ? .transient : .applicationDefined
        guard !p.isShown else { return }

        if let button = statusItem?.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if controller.state.displayMode.showsOrb {
            togglePopoverFromOrb()
            return
        } else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.markAllChatMessagesRead()
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if let p = popover, p.isShown {
            p.performClose(nil)
        } else {
            let p = popover ?? makePopover()
            popover = p
            p.behavior = controller.hasCompletedOnboardingWizard ? .transient : .applicationDefined
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            controller.markAllChatMessagesRead()
        }
    }

    /// Opens (or closes) the popover anchored directly beside the companion orb.
    /// Detects which half of the screen the orb is in and opens on the near side
    /// so the popover never jumps far from the cat. The anchor rect is shifted
    /// horizontally if needed to keep the popover fully on-screen.
    func togglePopoverFromOrb() {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        let p = popover ?? makePopover()
        popover = p
        p.behavior = controller.hasCompletedOnboardingWizard ? .transient : .applicationDefined

        if let wc = windowCoordinator,
           let placement = wc.screenPopoverPlacement(
                for: NSSize(width: ACD.popoverWidth, height: p.contentSize.height)
           ) {
            let anchorWindow = orbPopoverAnchorWindow ?? makeOrbPopoverAnchorWindow()
            orbPopoverAnchorWindow = anchorWindow
            anchorWindow.setFrame(placement.adjustedAnchorRect, display: false)
            anchorWindow.orderFrontRegardless()

            if let anchorView = anchorWindow.contentView {
                p.show(
                    relativeTo: anchorView.bounds,
                    of: anchorView,
                    preferredEdge: placement.preferredEdge
                )
            }
        } else if let button = statusItem?.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.markAllChatMessagesRead()
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        let isWizard = !controller.hasCompletedOnboardingWizard
        p.contentSize = NSSize(width: ACD.popoverWidth, height: isWizard ? 540 : 460)
        p.behavior = isWizard ? .applicationDefined : .transient
        p.animates = true
        p.delegate = self
        p.contentViewController = NSHostingController(
            rootView: PopoverRootView()
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

    private func makeOrbPopoverAnchorWindow() -> NSWindow {
        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: ACD.orbDiameter, height: ACD.orbDiameter))
        let window = NSWindow(
            contentRect: anchorView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = anchorView
        return window
    }

    func popoverDidClose(_ notification: Notification) {
        orbPopoverAnchorWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .acDismissSheet, object: nil)
    }

    // MARK: - Right-click context menu (minimal — full controls live in the popover)

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open AccountyCat",
                                   action: #selector(openMainPopoverFromMenu),
                                   keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        if controller.state.displayMode.showsOrb {
            let locateItem = NSMenuItem(title: "Locate AC",
                                        action: #selector(locateAC),
                                        keyEquivalent: "")
            locateItem.target = self
            menu.addItem(locateItem)
        }

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

    @objc private func locateAC() {
        guard controller.state.displayMode.showsOrb else { return }
        windowCoordinator?.playEntranceAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.openPopover()
        }
    }

    @objc private func closePopoverOnResignActive() {
        // Keep the popover open during onboarding so it stays visible
        // when the user returns from System Settings.
        guard controller.hasCompletedOnboardingWizard else { return }
        if let p = popover, p.isShown {
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

// MARK: - Popover root (wizard or chat)

private struct PopoverRootView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if controller.hasCompletedOnboardingWizard {
            ChatPanelView()
        } else {
            OnboardingWizardView()
        }
    }
}
