//
//  ACApp.swift
//  AC
//
//  App entry point. Menu bar icon with NSPopover — no separate settings window.
//  Left-click: toggle popover. Right-click: minimal context menu (pause / quit).
//  Status icon switches symbol based on companion mood.
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
    private let controller = AppController.shared
    private var statusItem: NSStatusItem?
    private var windowCoordinator: WindowCoordinator?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            hideOverlay: { [weak self] in     self?.windowCoordinator?.hideOverlay() }
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

        // Show popover on first launch if setup isn't complete
        if controller.state.setupStatus != .ready {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
        // Block until llama-server is actually killed. Without this the process
        // exits before the async Task inside shutdown() can run, orphaning the server.
        // Calling shutdown() a second time is a no-op if the server is already gone.
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await AppController.shared.localModelRuntime.shutdown()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5)
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
            item.button?.title = ""
        } else {
            item.button?.title = "AC"
        }
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
                case .paused:   symbol = "pause.circle.fill"
                case .setup:    symbol = "gearshape.fill"
                default:        symbol = "pawprint.fill"
                }
                self.applyIcon(symbolName: symbol, to: item)

                // Close the popover when a nudge fires so the speech bubble and
                // settings panel don’t overlap. The NSPopover instance is reused,
                // so SwiftUI @State (draft text, scroll position, etc.) is preserved.
                if mood == .nudging, let p = self.popover, p.isShown {
                    p.performClose(nil)
                }
            }
            .store(in: &cancellables)
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

    // MARK: - Popover

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        let p = popover ?? makePopover()
        popover = p
        guard !p.isShown else { return }
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if let p = popover, p.isShown {
            p.performClose(nil)
        } else {
            let p = popover ?? makePopover()
            popover = p
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.contentSize = NSSize(width: ACD.popoverWidth, height: 492)
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(controller)
        )
        return p
    }

    // MARK: - Right-click context menu (minimal — full controls live in the popover)

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

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
    @objc private func quitApp()      { NSApp.terminate(nil) }

    @objc private func closePopoverOnResignActive() {
        if let p = popover, p.isShown {
            p.performClose(nil)
        }
    }
}
