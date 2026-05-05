//
//  CallDetectionService.swift
//  AC
//
//  Detects whether the user is likely in a video call so AC can stay quiet.
//  Uses a combination of known app bundle IDs and on-screen window titles.
//

import AppKit
import CoreGraphics

enum CallDetectionService {
    /// Test hook: when non-nil, short-circuits all heuristics.
    @TaskLocal
    static var isInCallOverride: Bool?

    static func isInCall() -> Bool {
        if let override = isInCallOverride { return override }
        return checkNativeCallApps() || checkFrontmostBrowserInCall()
    }

    // MARK: - Native apps

    private static func checkNativeCallApps() -> Bool {
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard let indicators = nativeCallIndicators[bundleID] else { continue }
            for indicator in indicators {
                if anyOnScreenWindowTitle(for: app.processIdentifier, contains: indicator) {
                    return true
                }
            }
        }
        return false
    }

    private static let nativeCallIndicators: [String: [String]] = [
        "us.zoom.xos": ["Zoom Meeting", "Zoom Webinar"],
        "com.microsoft.teams": ["Microsoft Teams Call", "Microsoft Teams Meeting"],
        "com.microsoft.teams2": ["Microsoft Teams Call", "Microsoft Teams Meeting"],
        "com.apple.FaceTime": ["FaceTime"],
        "com.apple.facetime": ["FaceTime"],
        "com.cisco.webexmeetingsapp": ["Webex"],
        "com.cisco.webexteams": ["Webex"],
        "com.webex.meetingmanager": ["Webex"],
        "com.slack.Slack": ["Slack | Huddle", "Slack Call", "Huddle"],
    ]

    // MARK: - Browser-based calls

    private static func checkFrontmostBrowserInCall() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        guard let bundleID = frontmost.bundleIdentifier,
              MonitoringHeuristics.isBrowser(bundleIdentifier: bundleID) else { return false }
        guard let title = SnapshotService.focusedWindowTitle(for: frontmost) else { return false }
        let lowercased = title.lowercased()
        return browserCallIndicators.contains(where: { lowercased.contains($0) })
    }

    private static let browserCallIndicators: [String] = [
        "google meet",
        "zoom meeting",
        "zoom webinar",
        "teams meeting",
        "teams call",
        "webex",
        "gotomeeting",
        "skype",
        "whereby",
        "jitsi meet",
        "around",
    ]

    // MARK: - Window-list helper

    private static func anyOnScreenWindowTitle(for pid: pid_t, contains substring: String) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return false
        }
        for window in windows {
            guard let windowPID = window[kCGWindowOwnerPID] as? pid_t, windowPID == pid else { continue }
            if let title = (window[kCGWindowName] as? String)?.cleanedSingleLine,
               title.localizedCaseInsensitiveContains(substring) {
                return true
            }
        }
        return false
    }
}
