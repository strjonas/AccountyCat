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

    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType tracks real user activity (keyboard/mouse), unlike .null.
        guard let anyInput = CGEventType(rawValue: UInt32.max) else {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

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
           let focusedWindow = focusedWindowValue {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
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
        let image = try await captureImage(in: rect)

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

    private static func captureImage(in rect: CGRect) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await captureImageWithoutTimeout(in: rect)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: captureTimeoutSeconds * NSEC_PER_SEC)
                throw SnapshotError.captureTimedOut
            }

            let result = try await group.next()!
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

    private static func captureRect() -> CGRect {
        let frames = NSScreen.screens.map(\.frame)
        guard let first = frames.first else {
            return .zero
        }

        return frames.dropFirst().reduce(first) { partial, next in
            partial.union(next)
        }
    }

    private static func cgWindowTitle(for pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }

        let matchingWindow = windows.first { window in
            guard let ownerPID = window[kCGWindowOwnerPID] as? pid_t else {
                return false
            }
            return ownerPID == pid
        }

        return (matchingWindow?[kCGWindowName] as? String)?.cleanedSingleLine
    }

    private static func browserTabTitle(for app: NSRunningApplication) -> String? {
        guard let bundleIdentifier = app.bundleIdentifier,
              MonitoringHeuristics.isBrowser(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

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

        return runAppleScript(scriptSource)
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
