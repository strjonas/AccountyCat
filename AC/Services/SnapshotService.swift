//
//  SnapshotService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum SnapshotService {
    private static let captureTimeoutSeconds: UInt64 = 8
    private static let screenCapturePermissionErrorDomain = "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain"
    private static let screenCapturePermissionDeniedCode = 1004

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
    }

    private static let anyInputEventType: CGEventType = CGEventType(rawValue: ~0)!

    // MARK: - Browser tab title cache

    /// AppleScript execution is the dominant CPU sink (called every 2 s by `probeForContextChange`).
    /// Caching browser tab titles for a few seconds eliminates ~95 % of those spawns without
    /// meaningfully delaying detection of tab switches.
    private struct CachedBrowserTitle: @unchecked Sendable {
        let title: String
        let recordedAt: Date
    }

    private static let browserCacheLock = NSLock()
    private static var browserTitleCache: [pid_t: CachedBrowserTitle] = [:]
    private static let browserCacheTTL: TimeInterval = 10

    static func frontmostContext() -> FrontmostContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown App"
        let windowTitle = normalizedWindowTitle(
            focusedWindowTitle(for: app),
            appName: appName
        )

        return FrontmostContext(
            bundleIdentifier: app.bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle
        )
    }

    static func focusedWindowTitle(for app: NSRunningApplication) -> String? {
        if let browserTitle = browserTabTitle(for: app) {
            return browserTitle
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?

        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindowValue,
           CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            let focusedWindow = (focusedWindowValue as! AXUIElement)
            var titleValue: CFTypeRef? 
            if AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String,
               !title.cleanedSingleLine.isEmpty {
                return title.cleanedSingleLine
            }
        }

        return cgWindowTitle(for: app.processIdentifier)
    }

    private static func normalizedWindowTitle(_ title: String?, appName: String) -> String? {
        guard let cleaned = title?.cleanedSingleLine, !cleaned.isEmpty else {
            return nil
        }

        return MonitoringHeuristics.isUnhelpfulWindowTitle(cleaned, appName: appName) ? nil : cleaned
    }

    static func captureScreenshot() async throws -> URL {
        let rect = captureRect()
        return try await captureScreenshot(in: rect)
    }

    static func captureActiveWindowScreenshot() async throws -> URL {
        if CGPreflightScreenCaptureAccess() {
            if let window = try? await activeShareableWindow() {
                return try await captureScreenshot(of: window)
            }
        }

        if let windowRect = activeWindowRect() {
            return try await captureScreenshot(in: windowRect)
        }
        return try await captureScreenshot()
    }

    /// ScreenCaptureKit can keep failing after a dev rebuild invalidates the
    /// existing TCC grant for the app's current code identity. Treat those
    /// failures as permission loss so the UI can stop retrying screenshots
    /// until the user re-grants access.
    static func indicatesScreenCapturePermissionLoss(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == screenCapturePermissionErrorDomain
            && nsError.code == screenCapturePermissionDeniedCode
    }

    private static func captureScreenshot(in rect: CGRect) async throws -> URL {
        let image = try await captureImage(in: rect)
        return try writePNG(image)
    }

    private static func captureScreenshot(of window: SCWindow) async throws -> URL {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = windowCaptureConfiguration(for: filter)
        let image = try await captureImage(contentFilter: filter, configuration: configuration)
        return try writePNG(image)
    }

    private static func writePNG(_ image: CGImage) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-screenshot-\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.failedToCreateImageDestination
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.failedToWriteImage
        }

        return tempURL
    }

    private static func windowCaptureConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = false
        configuration.includeChildWindows = true

        let width = Self.pixelLength(points: filter.contentRect.width, scale: filter.pointPixelScale)
        let height = Self.pixelLength(points: filter.contentRect.height, scale: filter.pointPixelScale)
        configuration.width = width
        configuration.height = height
        return configuration
    }

    static func pixelLength(points: CGFloat, scale: Float) -> Int {
        max(1, Int(ceil(points * CGFloat(scale))))
    }

    private static func captureImage(in rect: CGRect) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await captureImageWithoutTimeout(in: rect)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: captureTimeoutSeconds * NSEC_PER_SEC)
                throw SnapshotError.captureTimedOut
            }

            guard let result = try await group.next() else {
                throw SnapshotError.captureTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    private static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await captureImageWithoutTimeout(contentFilter: contentFilter, configuration: configuration)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: captureTimeoutSeconds * NSEC_PER_SEC)
                throw SnapshotError.captureTimedOut
            }

            guard let result = try await group.next() else {
                throw SnapshotError.captureTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    private static func captureImageWithoutTimeout(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: SnapshotError.captureReturnedNoImage)
                }
            }
        }
    }

    private static func captureImageWithoutTimeout(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: SnapshotError.captureReturnedNoImage)
                }
            }
        }
    }

    private static func captureRect() -> CGRect {
        let frames = NSScreen.screens.map(\.frame)
        guard let first = frames.first else {
            return .zero
        }

        return frames.dropFirst().reduce(first) { partial, next in
            partial.union(next)
        }
    }

    private static func activeWindowRect() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if let target = cgFrontmostWindowTarget(for: app.processIdentifier) {
            return target.rect
        }

        return accessibilityWindowRect(for: app.processIdentifier)
    }

    private struct WindowCaptureTarget {
        var windowID: CGWindowID
        var rect: CGRect
    }

    private static func activeShareableWindow() async throws -> SCWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = app.processIdentifier
        let cgTarget = cgFrontmostWindowTarget(for: pid)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { window in
            guard window.owningApplication?.processID == pid,
                  window.windowLayer == 0,
                  window.isOnScreen,
                  isPlausibleCaptureRect(window.frame) else {
                return false
            }
            return true
        }

        if let cgTarget,
           let exact = windows.first(where: { $0.windowID == cgTarget.windowID }) {
            return exact
        }

        return windows.first
    }

    /// Returns the frontmost normal on-screen window for the given PID. CoreGraphics
    /// returns bounds in display-space coordinates, matching `captureImage(in:)`.
    private static func cgFrontmostWindowTarget(for pid: pid_t) -> WindowCaptureTarget? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns windows front-to-back, so the first
        // match for this PID is the app's frontmost on-screen window.
        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID] as? pid_t,
                  windowPID == pid,
                  (window[kCGWindowLayer] as? Int ?? 0) == 0,
                  (window[kCGWindowAlpha] as? Double ?? 1) > 0,
                  (window[kCGWindowIsOnscreen] as? Bool ?? true),
                  (window[kCGWindowSharingState] as? Int ?? 1) != 0,
                  let windowNumber = window[kCGWindowNumber] as? CGWindowID,
                  let boundsAny = window[kCGWindowBounds] else {
                continue
            }

            let boundsDict = boundsAny as! CFDictionary
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else {
                continue
            }

            guard isPlausibleCaptureRect(rect) else {
                continue
            }

            return WindowCaptureTarget(windowID: windowNumber, rect: rect)
        }

        return nil
    }

    /// Returns the focused-window rect via Accessibility APIs.
    /// Accessibility reports the global screen coordinates of the top-left corner,
    /// which is the same logical screen space used by ScreenCaptureKit rect capture.
    private static func accessibilityWindowRect(for pid: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        var focusedWindowValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = (focusedWindowValue as! AXUIElement)

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        let rect = CGRect(origin: position, size: size)
        return isPlausibleCaptureRect(rect) ? rect : nil
    }

    private static func isPlausibleCaptureRect(_ rect: CGRect) -> Bool {
        rect.width > 40 && rect.height > 40 && rect.width < 8000 && rect.height < 8000
    }

    private static func cgWindowTitle(for pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], CGWindowID(pid)) as? [[CFString: Any]] else {
            return nil
        }

        guard let matchingWindow = windows.first else { return nil }
        return (matchingWindow[kCGWindowName] as? String)?.cleanedSingleLine
    }

    private static func browserTabTitle(for app: NSRunningApplication) -> String? {
        guard let bundleIdentifier = app.bundleIdentifier,
              MonitoringHeuristics.isBrowser(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let pid = app.processIdentifier
        let now = Date()

        browserCacheLock.lock()
        if let cached = browserTitleCache[pid], now.timeIntervalSince(cached.recordedAt) < browserCacheTTL {
            browserCacheLock.unlock()
            return cached.title
        }
        browserCacheLock.unlock()

        let scriptSource: String
        switch bundleIdentifier {
        case "com.apple.Safari":
            scriptSource = """
            tell application id \"\(bundleIdentifier)\"
                if (count of windows) is 0 then return \"\"
                return name of current tab of front window
            end tell
            """
        default:
            scriptSource = """
            tell application id \"\(bundleIdentifier)\"
                if (count of windows) is 0 then return \"\"
                return title of active tab of front window
            end tell
            """
        }

        let result = runAppleScript(scriptSource)

        browserCacheLock.lock()
        if let result {
            browserTitleCache[pid] = CachedBrowserTitle(title: result, recordedAt: now)
        }
        browserCacheLock.unlock()

        return result
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        var scriptError: NSDictionary?
        let descriptor = script.executeAndReturnError(&scriptError)
        guard scriptError == nil else {
            return nil
        }

        let value = descriptor.stringValue?.cleanedSingleLine
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum SnapshotError: LocalizedError {
    case failedToCreateImageDestination
    case failedToWriteImage
    case captureReturnedNoImage
    case captureTimedOut

    var errorDescription: String? {
        switch self {
        case .failedToCreateImageDestination:
            return "AC could not create a PNG destination for the screenshot."
        case .failedToWriteImage:
            return "AC could not write the screenshot to disk."
        case .captureReturnedNoImage:
            return "Screen capture returned no image."
        case .captureTimedOut:
            return "Screen capture timed out."
        }
    }
}
