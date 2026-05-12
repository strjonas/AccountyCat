//
//  WindowCoordinator.swift
//  AC
//
//  Manages the floating companion panel and escalation overlay.
//  Nudges now appear as speech bubbles inside the companion — no separate panel.
//
//  Drag is handled via NSEvent local monitor rather than SwiftUI DragGesture;
//  this bypasses the SwiftUI render-loop delay and gives butter-smooth movement.
//

import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
    private let controller: AppController
    private let nudgeScreenInset: CGFloat = 12

    private(set) var companionPanel: PassivePanel?
    private var overlayWindow: NSWindow?
    private var entranceWindow: NSWindow?
    private var statusBarNudgePanel: NSPanel?

    var isOverlayVisible: Bool { overlayWindow?.isVisible == true }
    private var nudgeBorderWindow: NSWindow?
    private var dismissNudgeWorkItem: DispatchWorkItem?
    private var nudgeRestoreFrame: NSRect?
    private var nudgeAdjustedFrame: NSRect?
    private var nudgeRestorePeekingEdge: NSRectEdge?
    private var nudgePanelExpanded = false

    // Native-event drag state (replaces SwiftUI DragGesture)
    private var dragEventMonitor: Any?
    private var dragStartScreenPoint: NSPoint?
    private var panelFrameAtDragStart: NSRect?
    private var isDraggingPanel = false

    // Edge-peek: if the orb is within this many points of a horizontal or bottom
    // edge the panel snaps flush and only half the orb is visible.
    private let peekThreshold: CGFloat = 50

    /// Which edge (if any) the orb is currently peeking over.
    /// Written through to AppController so CompanionView can observe it.
    private var peekingEdge: NSRectEdge? {
        get { controller.peekingEdge }
        set { controller.peekingEdge = newValue }
    }

    // Position persistence keys
    private let posXKey = "acCompanionX"
    private let posYKey = "acCompanionY"

    /// Set by AppDelegate so the orb tap can open the popover even when the
    /// menu bar status item is hidden behind macOS's overflow ( >> ).
    var openPopoverFromOrb: (() -> Void)?

    /// Returns the status item button frame in screen coordinates.
    /// Set by AppDelegate so the status bar nudge can anchor near the menu bar.
    var statusItemButtonFrameProvider: (() -> NSRect)?

    init(controller: AppController) {
        self.controller = controller
    }

    // MARK: - Companion

    func showCompanion() {
        let panel = companionPanel ?? makeCompanionPanel()
        companionPanel = panel
        let frame = savedCompanionFrame()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        recomputePeekingEdge(for: frame)
    }

    private func recomputePeekingEdge(for frame: NSRect) {
        let orbCenter = CompanionGeometry.orbCenter(forPanelFrame: frame)
        let screen = screenContaining(point: orbCenter) ?? activeScreen()
        let vf = screen.visibleFrame
        let threshold: CGFloat = 4
        if abs(orbCenter.x - vf.minX) < threshold {
            peekingEdge = .minX
        } else if abs(orbCenter.x - vf.maxX) < threshold {
            peekingEdge = .maxX
        } else if abs(orbCenter.y - vf.minY) < threshold {
            peekingEdge = .minY
        } else {
            peekingEdge = nil
        }
    }

    func hideCompanion() {
        companionPanel?.orderOut(nil)
    }

    // MARK: - Entrance animation

    func playEntranceAnimation(completion: (() -> Void)? = nil) {
        guard let panel = companionPanel else {
            completion?()
            return
        }

        let orbCenter = CompanionGeometry.orbCenter(forPanelFrame: panel.frame)
        let size: CGFloat = 300
        let frame = NSRect(
            x: orbCenter.x - size / 2,
            y: orbCenter.y - size / 2,
            width: size,
            height: size
        )

        let accent = controller.state.character.accentColor

        let hosting = NSHostingController(
            rootView: CompanionEntranceView(accent: accent, onComplete: { [weak self] in
                self?.entranceWindow?.orderOut(nil)
                self?.entranceWindow = nil
                completion?()
            })
        )

        let window = NSWindow(
            contentRect: frame,
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
        window.contentViewController = hosting

        let hostingView = hosting.view
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        entranceWindow?.orderOut(nil)
        entranceWindow = window
        window.orderFrontRegardless()
    }

    // MARK: - Native drag monitor
    //
    // Using NSEvent.addLocalMonitorForEvents gives us raw event callbacks
    // *before* SwiftUI's render loop, eliminating the 1-frame lag that caused
    // the "resistance" feeling with DragGesture.

    private func setupDragMonitor(for panel: PassivePanel) {
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak panel] event in
            guard let self, let panel else { return event }

            switch event.type {

            case .leftMouseDown:
                let loc = NSEvent.mouseLocation
                if panel.frame.contains(loc) {
                    self.dragStartScreenPoint = loc
                    self.panelFrameAtDragStart = panel.frame
                    self.isDraggingPanel = false
                } else {
                    self.dragStartScreenPoint = nil
                }

            case .leftMouseDragged:
                guard let startLoc = self.dragStartScreenPoint,
                      let startFrame = self.panelFrameAtDragStart else { break }
                let loc = NSEvent.mouseLocation
                let dx = loc.x - startLoc.x
                let dy = loc.y - startLoc.y

                if !self.isDraggingPanel && (abs(dx) > 2 || abs(dy) > 2) {
                    self.isDraggingPanel = true
                }

                if self.isDraggingPanel {
                    let pw = panel.frame.width
                    let halfOrb = ACD.orbDiameter / 2
                    let orbBottomPad = CompanionGeometry.orbBottomPadding
                    let startOrbX = startFrame.origin.x + pw / 2
                    let startOrbY = startFrame.origin.y + orbBottomPad + halfOrb
                    let desiredOrbCenter = NSPoint(x: startOrbX + dx, y: startOrbY + dy)
                    let screen = self.screenContaining(point: desiredOrbCenter) ?? self.activeScreen()
                    let clampFrame = screen.visibleFrame

                    // ── Orb-centre-based clamping ────────────────────────────
                    // Track the ORB CENTRE rather than the panel origin so the
                    // orb can reach every pixel of the active display while the
                    // transparent panel itself remains free to extend beyond it.
                    //
                    // Screen-coord note: AppKit Y increases upward.
                    //   orbCentreY = panelOriginY + orbBottomPad + halfOrb

                    // Orb can go anywhere horizontally; vertically it stops just
                    // below the menu bar and can reach the screen bottom.
                    var orbX = desiredOrbCenter.x
                        .acClamped(to: clampFrame.minX ... clampFrame.maxX)
                    var orbY = desiredOrbCenter.y
                        .acClamped(to: clampFrame.minY ... max(clampFrame.minY, clampFrame.maxY - 8))

                    // ── Edge-peek snapping ────────────────────────────────────
                    // When the orb centre comes within peekThreshold of a side
                    // or bottom edge, snap flush so exactly half the orb peeks.
                    var newPeek: NSRectEdge? = nil

                    if orbX - clampFrame.minX < self.peekThreshold {
                        orbX   = clampFrame.minX
                        newPeek = .minX
                    } else if clampFrame.maxX - orbX < self.peekThreshold {
                        orbX   = clampFrame.maxX
                        newPeek = .maxX
                    }

                    if orbY - clampFrame.minY < self.peekThreshold {
                        orbY   = clampFrame.minY
                        newPeek = .minY
                    }

                    self.peekingEdge = newPeek

                    // Convert back to panel origin
                    let newX = orbX - pw / 2
                    let newY = orbY - orbBottomPad - halfOrb

                    panel.setFrame(
                        NSRect(origin: NSPoint(x: newX, y: newY), size: panel.frame.size),
                        display: false
                    )
                }

            case .leftMouseUp:
                if self.isDraggingPanel {
                    self.saveCompanionPosition()
                }
                self.dragStartScreenPoint = nil
                self.panelFrameAtDragStart = nil
                self.isDraggingPanel = false

            default:
                break
            }

            return event  // always pass through — lets SwiftUI TapGesture fire for taps
        }
    }

    // MARK: - Screen recovery

    private func recoverCompanionIfOffScreen() {
        guard let panel = companionPanel else { return }
        let orbCenter = CompanionGeometry.orbCenter(forPanelFrame: panel.frame)
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.contains(orbCenter) }
        guard !isOnScreen else { return }
        let target = defaultCompanionFrame()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            panel.animator().setFrame(target, display: true)
        }
        saveCompanionPosition()
    }

    // MARK: - Nudge (speech bubble edition)

    func showNudge(message: String) {
        if controller.state.displayMode.showsOrb {
            showOrbNudge(message: message)
        } else {
            showStatusBarNudge(message: message)
        }
    }

    private func showOrbNudge(message: String) {
        adjustCompanionForVisibleNudgeIfNeeded()
        expandPanelForNudge()
        controller.recordDisplayedNudge(message)
        showNudgeBorder()
        triggerHaptic()

        if UserDefaults.standard.bool(forKey: "acSoundEnabled") {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }

        dismissNudgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restoreCompanionAfterNudgeIfNeeded()
            self?.controller.clearTransientUI()
            self?.hideNudgeBorder()
        }
        dismissNudgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    private func showStatusBarNudge(message: String) {
        controller.recordDisplayedNudge(message)
        showNudgeBorder()
        triggerHaptic()

        if UserDefaults.standard.bool(forKey: "acSoundEnabled") {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }

        let panel = statusBarNudgePanel ?? makeStatusBarNudgePanel()
        statusBarNudgePanel = panel

        // Position below the status bar area at the top-right of the screen
        let screen = activeScreen()
        let vf = screen.visibleFrame
        let sf = screen.frame
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 180

        // Try to get the button frame; fall back to top-right of visible area
        let panelX: CGFloat
        let panelTopY: CGFloat
        if let buttonFrame = statusItemButtonFrameProvider?(), buttonFrame.width > 0 {
            panelX = buttonFrame.midX - panelWidth / 2
            // buttonFrame is in screen coords (origin bottom-left).
            // The nudge should hang just below the button.
            panelTopY = buttonFrame.minY - 4
        } else {
            panelX = vf.maxX - panelWidth - 16
            // Menu bar is above the visible frame; place panel just below it
            panelTopY = vf.maxY - (sf.height - vf.maxY) - 4
        }

        // Clamp X within screen
        let clampedX = max(vf.minX + 8, min(panelX, vf.maxX - panelWidth - 8))

        // Update the SwiftUI content before setting the frame — otherwise
        // NSWindow.contentViewController replacement can auto-resize the panel.
        let onRate: (Bool) -> Void = { [weak self] positive in
            self?.dismissNudgeWorkItem?.cancel()
            self?.dismissStatusBarNudge()
            self?.controller.rateNudge(positive: positive, nudgeText: message)
            self?.hideNudgeBorder()
        }
        let view = StatusBarNudgeView(text: message, onRate: onRate)
            .environmentObject(controller)
            .acAccent(for: controller.state)
        let hosting = NSHostingController(rootView: AnyView(view))
        panel.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.isOpaque = false
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        // panel.setFrame uses bottom-left origin, so subtract height
        let panelY = panelTopY - panelHeight
        panel.setFrame(NSRect(x: clampedX, y: panelY, width: panelWidth, height: panelHeight), display: true)

        panel.orderFrontRegardless()

        dismissNudgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dismissStatusBarNudge()
            self?.controller.clearTransientUI()
            self?.hideNudgeBorder()
        }
        dismissNudgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    private func dismissStatusBarNudge() {
        statusBarNudgePanel?.orderOut(nil)
    }

    func dismissStatusBarNudgePanel() {
        dismissStatusBarNudge()
    }

    private func makeStatusBarNudgePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: AnyView(
            StatusBarNudgeView(text: "", onRate: nil)
                .environmentObject(controller)
                .acAccent(for: controller.state)
        ))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.isOpaque = false
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        return panel
    }

    private func expandPanelForNudge() {
        guard let panel = companionPanel, !nudgePanelExpanded else { return }
        let screen = screenContainingOrb(for: panel) ?? activeScreen()
        var f = panel.frame
        let bonus: CGFloat = 360
        let topCap = screen.visibleFrame.maxY - 8
        f.size.height = min(f.size.height + bonus, max(topCap - f.minY, ACD.panelHeight + 80))
        panel.setFrame(f, display: false)
        nudgePanelExpanded = true
    }

    private func collapsePanelAfterNudge() {
        guard let panel = companionPanel, nudgePanelExpanded else { return }
        var f = panel.frame
        f.size.height = ACD.panelHeight
        panel.setFrame(f, display: false)
        nudgePanelExpanded = false
    }

    // MARK: - Overlay

    func showOverlay(presentation: OverlayPresentation) {
        controller.activeOverlay = presentation
        controller.overlayAppealDraft = ""
        controller.overlayVisible = true
        let window = overlayWindow ?? makeOverlayWindow()
        overlayWindow = window
        window.setFrame(activeScreen().frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hideOverlay() {
        overlayWindow?.orderOut(nil)
        controller.overlayVisible = false
        controller.activeOverlay = nil
        controller.overlayAppealDraft = ""
        controller.sendingOverlayAppeal = false
    }

    // MARK: - Popover anchor

    /// Returns the rect (in contentView coordinates) centred on the orb.
    /// NSHostingView IS flipped (Y=0 at the TOP, values increase downward),
    /// so the orb near the visual bottom has a high Y value in view-coords.
    func orbAnchorRect(in contentView: NSView) -> NSRect {
        let orbD = ACD.orbDiameter
        let bottomPad = CompanionGeometry.orbBottomPadding
        let viewH = contentView.bounds.height
        // Flipped-coord Y: measure from the top of the view
        let orbCentreY = viewH - bottomPad - orbD / 2
        return NSRect(
            x: contentView.bounds.midX - orbD / 2,
            y: orbCentreY - orbD / 2,
            width: orbD,
            height: orbD
        )
    }

    /// True when the orb centre is in the lower half of its screen.
    /// Uses the actual orb position (not panel midY) for accuracy.
    var orbIsInBottomHalf: Bool {
        guard let panel = companionPanel else { return true }
        let screen = screenContainingOrb(for: panel) ?? activeScreen()
        let orbCentreY = CompanionGeometry.orbCenter(forPanelFrame: panel.frame).y
        return orbCentreY < screen.frame.midY
    }

    func screenPopoverPlacement(for popoverSize: NSSize) -> CompanionPopoverPlacement? {
        guard let panel = companionPanel else { return nil }
        let screen = screenContainingOrb(for: panel) ?? activeScreen()
        let orbCenter = CompanionGeometry.orbCenter(forPanelFrame: panel.frame)
        let anchorRect = NSRect(
            x: orbCenter.x - ACD.orbDiameter / 2,
            y: orbCenter.y - ACD.orbDiameter / 2,
            width: ACD.orbDiameter,
            height: ACD.orbDiameter
        )

        return CompanionGeometry.popoverPlacement(
            for: anchorRect,
            in: screen.visibleFrame,
            popoverSize: popoverSize
        )
    }

    // MARK: - Factories

    private func makeCompanionPanel() -> PassivePanel {
        // CompanionView no longer needs onDrag/onDragEnd — drag is handled by
        // the NSEvent monitor above. Only onTap is needed for popover toggle.
        let view = CompanionView(
            onTap: { [weak self] in self?.openPopoverFromOrb?() }
        )
        .environmentObject(controller)
        .background(.clear)

        let hosting = NSHostingController(rootView: view)
        let panel = PassivePanel(
            contentRect: savedCompanionFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentViewController = hosting
        // Fully transparent hosting view — without all three of these the
        // NSHostingView paints a window-background-coloured rectangle behind the orb.
        hosting.view.wantsLayer = true
        hosting.view.layer?.isOpaque = false
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        // Save position whenever the panel moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveCompanionPosition() }
        }

        // Recover the orb if a monitor is disconnected while the app is running
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverCompanionIfOffScreen() }
        }

        setupDragMonitor(for: panel)
        return panel
    }

    private func makeOverlayWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: OverlayView()
                .environmentObject(controller)
                .acAccent(for: controller.state)
        )
        let window = OverlayWindow(
            contentRect: activeScreen().frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.contentViewController = hosting

        // Borderless windows do not become key by default; this custom
        // subclass allows TextField focus and button interaction.
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false

        let hostingView = hosting.view
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        return window
    }

    // MARK: - Position persistence

    private func defaultCompanionFrame() -> NSRect {
        let screen = activeScreen()
        return NSRect(
            x: screen.visibleFrame.maxX - ACD.panelWidth - 16,
            y: screen.visibleFrame.minY + 24,
            width: ACD.panelWidth,
            height: ACD.panelHeight
        )
    }

    private func savedCompanionFrame() -> NSRect {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: posXKey) != nil else { return defaultCompanionFrame() }
        let x = defaults.double(forKey: posXKey)
        let y = defaults.double(forKey: posYKey)
        let frame = NSRect(x: x, y: y, width: ACD.panelWidth, height: ACD.panelHeight)
        let orbCenter = CompanionGeometry.orbCenter(forPanelFrame: frame)
        let isOnScreen = NSScreen.screens.contains { screen in
            let vf = screen.visibleFrame
            // Allow a 4-point tolerance so edge-peeking orbs (whose centre sits
            // exactly on the visible-frame boundary) are not treated as off-screen.
            return orbCenter.x >= vf.minX - 4 && orbCenter.x <= vf.maxX + 4
                && orbCenter.y >= vf.minY - 4 && orbCenter.y <= vf.maxY + 4
        }
        return isOnScreen ? frame : defaultCompanionFrame()
    }

    private func saveCompanionPosition() {
        guard let panel = companionPanel else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(panel.frame.origin.x), forKey: posXKey)
        defaults.set(Double(panel.frame.origin.y), forKey: posYKey)
    }

    // MARK: - Nudge border

    private func showNudgeBorder() {
        let screen = currentOrbScreen() ?? activeScreen()
        let window = nudgeBorderWindow ?? makeNudgeBorderWindow(screen: screen)
        nudgeBorderWindow = window
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        if let hosting = window.contentViewController as? NSHostingController<NudgeBorderView> {
            let ch = controller.state.character
            hosting.rootView = NudgeBorderView(
                visible: true,
                tint: ch.escalatedRingColor,
                ringTint: ch.ringColor
            )
        }
    }

    private func hideNudgeBorder() {
        guard let window = nudgeBorderWindow,
              let hosting = window.contentViewController as? NSHostingController<NudgeBorderView> else {
            return
        }
        let ch = controller.state.character
        hosting.rootView = NudgeBorderView(
            visible: false,
            tint: ch.escalatedRingColor,
            ringTint: ch.ringColor
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.nudgeBorderWindow?.orderOut(nil)
        }
    }

    private func makeNudgeBorderWindow(screen: NSScreen) -> NSWindow {
        let ch = controller.state.character
        let hosting = NSHostingController(rootView: NudgeBorderView(
            visible: false,
            tint: ch.escalatedRingColor,
            ringTint: ch.ringColor
        ))
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentViewController = hosting
        return window
    }

    // MARK: - Nudge visibility near screen edges

    /// If the orb is peeking or close to an edge, temporarily bring the
    /// companion panel on-screen so the speech bubble is readable.
    private func adjustCompanionForVisibleNudgeIfNeeded() {
        guard let panel = companionPanel else { return }

        let screen = screenContainingOrb(for: panel) ?? activeScreen()
        let visible = screen.visibleFrame
        let target = CompanionGeometry.clampedPanelFrame(
            panel.frame,
            within: visible,
            margin: nudgeScreenInset
        )

        let movedX = abs(target.origin.x - panel.frame.origin.x)
        let movedY = abs(target.origin.y - panel.frame.origin.y)
        guard movedX > 0.5 || movedY > 0.5 else {
            return
        }

        nudgeRestoreFrame = panel.frame
        nudgeRestorePeekingEdge = peekingEdge
        nudgeAdjustedFrame = target
        peekingEdge = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Restore the previous edge-peek frame after the nudge disappears unless
    /// the user moved the orb while the nudge was visible. Always collapses the
    /// expanded panel height regardless of whether position was restored.
    private func restoreCompanionAfterNudgeIfNeeded() {
        defer {
            nudgeRestoreFrame = nil
            nudgeAdjustedFrame = nil
            nudgeRestorePeekingEdge = nil
        }

        guard let panel = companionPanel else {
            nudgePanelExpanded = false
            return
        }

        // If we had repositioned the orb for the nudge, restore position.
        // nudgeRestoreFrame has the pre-expansion height, so restoring it
        // also implicitly restores the height in the animated frame.
        if let restore = nudgeRestoreFrame, let adjusted = nudgeAdjustedFrame {
            let dx = panel.frame.origin.x - adjusted.origin.x
            let dy = panel.frame.origin.y - adjusted.origin.y
            let movedDuringNudge = hypot(dx, dy) > 2
            nudgePanelExpanded = false
            if !movedDuringNudge {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    panel.animator().setFrame(restore, display: true)
                }
                peekingEdge = nudgeRestorePeekingEdge
                saveCompanionPosition()
                return
            }
        }

        // No position restore (or user moved orb) — just collapse height.
        collapsePanelAfterNudge()
    }

    // MARK: - Screen edge safety

    // MARK: - Helpers

    private func triggerHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .default
        )
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return screenContaining(point: mouse)
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func currentOrbScreen() -> NSScreen? {
        guard let panel = companionPanel else { return nil }
        return screenContainingOrb(for: panel)
    }

    private func screenContainingOrb(for panel: NSWindow) -> NSScreen? {
        screenContaining(point: CompanionGeometry.orbCenter(forPanelFrame: panel.frame))
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? nearestScreen(to: point)
    }

    private func nearestScreen(to point: NSPoint) -> NSScreen? {
        NSScreen.screens.min { lhs, rhs in
            distance(from: point, to: lhs.frame) < distance(from: point, to: rhs.frame)
        }
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }
}

// MARK: - Passive Panel

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - CGFloat clamping helper

extension CGFloat {
    func acClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
