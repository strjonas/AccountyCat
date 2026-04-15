//
//  PermissionService.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PermissionService {
    static func currentSnapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            accessibility: AXIsProcessTrusted() ? .granted : .denied
        )
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
