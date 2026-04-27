//
//  PermissionService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation
import ScreenCaptureKit

enum PermissionService {
    static func currentSnapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            calendar: currentCalendarState()
        )
    }

    /// Calendar permission is opt-in (hidden behind the Calendar Intelligence
    /// toggle in Settings). We report its state here so the UI can mirror it,
    /// but never gate core monitoring on it.
    static func currentCalendarState() -> PermissionState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            case .notDetermined: return .unknown
            @unknown default: return .unknown
            }
        } else {
            switch status {
            case .authorized, .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            case .notDetermined: return .unknown
            @unknown default: return .unknown
            }
        }
    }

    /// Prompts for calendar access via EventKit. On denial or prior denial,
    /// bounces the user to the system Privacy pane so they can flip it back
    /// on — same fallback pattern used for Screen Recording and Accessibility.
    @discardableResult
    static func requestCalendarAccess() async -> Bool {
        let granted = await CalendarService.shared.requestAccess()
        if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
        return granted
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        
        if !granted {
            // Force macOS to register the app in the privacy list by attempting a dummy capture
            Task {
                // Ignore any error; this is purely to trigger the system daemon to register the app.
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            
            // Open System Settings directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        
        return granted
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        
        // If the prompt was already dismissed previously, AXIsProcessTrustedWithOptions returns false
        // and doesn't show the prompt again. We should open the settings.
        if !granted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        
        return granted
    }
}
