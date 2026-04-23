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

    private(set) var companionPanel: PassivePanel?
    private var overlayWindow: NSWindow?
    private var nudgeBorderWindow: NSWindow?
    private var dismissNudgeWorkItem: DispatchWorkItem?
    private var nudgeRestoreFrame: NSRect?
    private var nudgeAdjustedFrame: NSRect?
    private var nudgeRestorePeekingEdge: NSRectEdge?

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

    init(controller: AppController) {
        self.controller = controller
    }

    // MARK: - Companion

    func showCompanion() {
        let panel = companionPanel ?? makeCompanionPanel()
        companionPanel = panel
        panel.setFrame(savedCompanionFrame(), display: true)
        panel.orderFrontRegardless()

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
                    let screen = self.screenContaining(panel) ?? self.activeScreen()
                    let sf = screen.frame           // full display bounds
                    let vf = screen.visibleFrame    // excludes dock & menu bar
                    let pw  = panel.frame.width
                    let halfOrb = ACD.orbDiameter / 2
                    let orbBottomPad: CGFloat = 14

                    // ── Orb-centre-based clamping ────────────────────────────
                    // Track the ORB CENTRE rather than the panel origin so the
                    // orb can reach every pixel of the screen (panel may go
                    // partially off-screen on sides / bottom, which is fine since
                    // the panel is fully transparent outside the orb).
                    //
                    // Screen-coord note: AppKit Y increases upward.
                    //   orbCentreY = panelOriginY + orbBottomPad + halfOrb

                    let startOrbX = startFrame.origin.x + pw / 2
                    let startOrbY = startFrame.origin.y + orbBottomPad + halfOrb

                    // Orb can go anywhere horizontally; vertically it stops just
                    // below the menu bar and can reach the screen bottom.
                    var orbX = (startOrbX + dx)
                        .acClamped(to: sf.minX ... sf.maxX)
                    var orbY = (startOrbY + dy)
                        .acClamped(to: sf.minY ... vf.maxY - 8)

                    // ── Edge-peek snapping ────────────────────────────────────
                    // When the orb centre comes within peekThreshold of a side
                    // or bottom edge, snap flush so exactly half the orb peeks.
                    var newPeek: NSRectEdge? = nil

                    if orbX - sf.minX < self.peekThreshold {
                        orbX   = sf.minX                // orb centre AT left edge
                        newPeek = .minX
                    } else if sf.maxX - orbX < self.peekThreshold {
                        orbX   = sf.maxX                // orb centre AT right edge
                        newPeek = .maxX
                    }

                    if orbY - sf.minY < self.peekThreshold {
                        orbY   = sf.minY                // orb centre AT bottom edge
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
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
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
        adjustCompanionForVisibleNudgeIfNeeded()
        controller.latestNudge = message
        showNudgeBorder()
        triggerHaptic()

        if UserDefaults.standard.bool(forKey: "acSoundEnabled") {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }

        // Auto-dismiss after 7 s
        dismissNudgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restoreCompanionAfterNudgeIfNeeded()
            self?.controller.clearTransientUI()
            self?.hideNudgeBorder()
        }
        dismissNudgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
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
        let bottomPad: CGFloat = 14
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
        let screen = screenContaining(panel) ?? activeScreen()
        // Orb centre in screen coords (AppKit, Y up)
        let orbCentreY = panel.frame.minY + 14 + ACD.orbDiameter / 2
        return orbCentreY < screen.frame.midY
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
        return panel
    }

    private func makeOverlayWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: OverlayView().environmentObject(controller))
        let window = NSWindow(
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
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
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
        let screen = activeScreen()
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

        let screen = screenContaining(panel) ?? activeScreen()
        let visible = screen.visibleFrame
        let frame = panel.frame
        let inset: CGFloat = 8
        let orbCentreX = frame.midX
        let leftDistance = orbCentreX - screen.frame.minX
        let rightDistance = screen.frame.maxX - orbCentreX
        let nearestSideDistance = min(leftDistance, rightDistance)
        let nearSideThreshold = peekThreshold + 26
        let isPartiallyOffscreen =
            frame.minX < screen.frame.minX + inset
            || frame.maxX > screen.frame.maxX - inset
        let sidePeek = peekingEdge == .minX || peekingEdge == .maxX
        let topOverflow = frame.maxY > visible.maxY - inset
        let bottomOverflow = frame.minY < screen.frame.minY + inset
        let needsVerticalAdjust = topOverflow || bottomOverflow

        guard sidePeek
            || isPartiallyOffscreen
            || nearestSideDistance < nearSideThreshold
            || needsVerticalAdjust else {
            return
        }

        var target = panel.frame
        let moveTowardLeft = leftDistance <= rightDistance

        if moveTowardLeft {
            target.origin.x = screen.frame.minX + inset
        } else {
            target.origin.x = screen.frame.maxX - target.width - inset
        }

        // Keep full nudge panel visible vertically. This covers cases where
        // AC is near the menu bar and the bubble would otherwise be clipped.
        if target.maxY > visible.maxY - inset {
            target.origin.y = visible.maxY - target.height - inset
        }
        if target.minY < screen.frame.minY + inset {
            target.origin.y = screen.frame.minY + inset
        }

        let movedX = abs(target.origin.x - panel.frame.origin.x)
        let movedY = abs(target.origin.y - panel.frame.origin.y)
        guard movedX > 0.5 || movedY > 0.5 else { return }

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
    /// the user moved the orb while the nudge was visible.
    private func restoreCompanionAfterNudgeIfNeeded() {
        guard let panel = companionPanel,
              let restore = nudgeRestoreFrame,
              let adjusted = nudgeAdjustedFrame else {
            nudgeRestoreFrame = nil
            nudgeAdjustedFrame = nil
            nudgeRestorePeekingEdge = nil
            return
        }

        let dx = panel.frame.origin.x - adjusted.origin.x
        let dy = panel.frame.origin.y - adjusted.origin.y
        let movedDuringNudge = hypot(dx, dy) > 2

        defer {
            nudgeRestoreFrame = nil
            nudgeAdjustedFrame = nil
            nudgeRestorePeekingEdge = nil
        }

        guard !movedDuringNudge else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().setFrame(restore, display: true)
        }
        peekingEdge = nudgeRestorePeekingEdge
        saveCompanionPosition()
    }

    // MARK: - Helpers

    private func triggerHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .default
        )
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func screenContaining(_ panel: NSWindow) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panel.frame) }
    }
}

// MARK: - Passive Panel

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - CGFloat clamping helper

private extension CGFloat {
    func acClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
