//
//  AppFocusAXObserver.swift
//  AC
//

import ApplicationServices
import Foundation

@MainActor
final class AppFocusAXObserver {
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedWindowElement: AXUIElement?
    private var observedPID: pid_t?
    private var onChange: (() -> Void)?
    private(set) var uncooperativePIDs: Set<pid_t> = []

    func attach(pid: pid_t, onChange: @escaping () -> Void) -> Bool {
        detach()
        self.onChange = onChange

        var createdObserver: AXObserver?
        let status = AXObserverCreate(
            pid,
            { _, _, notification, refcon in
                guard let refcon else { return }
                // The refcon is safe to use unretained because BrainService owns this
                // observer strongly and always detaches before releasing that owner.
                let instance = Unmanaged<AppFocusAXObserver>.fromOpaque(refcon).takeUnretainedValue()
                instance.handleCallback(notification: notification as String)
            },
            &createdObserver
        )
        guard status == .success, let createdObserver else {
            uncooperativePIDs.insert(pid)
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let focusWindowStatus = AXObserverAddNotification(
            createdObserver,
            appElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        guard focusWindowStatus == .success || focusWindowStatus == .notificationAlreadyRegistered else {
            uncooperativePIDs.insert(pid)
            detach()
            return false
        }

        observer = createdObserver
        applicationElement = appElement
        observedPID = pid
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        guard subscribeToFocusedWindowTitleChanges(refcon: refcon) else {
            uncooperativePIDs.insert(pid)
            detach()
            return false
        }

        uncooperativePIDs.remove(pid)
        return true
    }

    func isKnownUncooperative(pid: pid_t) -> Bool {
        uncooperativePIDs.contains(pid)
    }

    func detach() {
        if let observer {
            if let applicationElement {
                AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    kAXFocusedWindowChangedNotification as CFString
                )
            }
            if let focusedWindowElement {
                AXObserverRemoveNotification(
                    observer,
                    focusedWindowElement,
                    kAXTitleChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observer = nil
        applicationElement = nil
        focusedWindowElement = nil
        observedPID = nil
        onChange = nil
    }

    private func handleCallback(notification: String) {
        guard let pid = observedPID else { return }
        if notification == kAXFocusedWindowChangedNotification as String {
            _ = subscribeToFocusedWindowTitleChanges(
                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
        }
        SnapshotService.invalidateBrowserTitleCache(pid: pid)
        onChange?()
    }

    private func subscribeToFocusedWindowTitleChanges(refcon: UnsafeMutableRawPointer) -> Bool {
        guard let observer, let applicationElement else { return false }
        if let focusedWindowElement {
            AXObserverRemoveNotification(
                observer,
                focusedWindowElement,
                kAXTitleChangedNotification as CFString
            )
            self.focusedWindowElement = nil
        }

        var focusedWindowValue: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard copyStatus == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()
        else {
            return true
        }

        let windowElement = focusedWindowValue as! AXUIElement
        let titleStatus = AXObserverAddNotification(
            observer,
            windowElement,
            kAXTitleChangedNotification as CFString,
            refcon
        )
        guard titleStatus == .success || titleStatus == .notificationAlreadyRegistered else {
            return false
        }

        focusedWindowElement = windowElement
        return true
    }
}
