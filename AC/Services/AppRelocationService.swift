//
//  AppRelocationService.swift
//  AC
//
//  Ensures AC runs from /Applications. When a quarantined download is launched
//  from ~/Downloads (or anywhere outside /Applications), macOS "translocates" it
//  to a random read-only path. TCC permission grants (Screen Recording,
//  Accessibility) are keyed to the bundle path, so from a translocated/quarantined
//  location they never stick — the user grants a permission and AC still reports it
//  as missing. Moving the app into /Applications once, before onboarding, makes
//  permissions reliable and is also how a normal install is expected to look.
//

import AppKit
import Foundation

enum AppRelocationService {

    // MARK: - Detection

    static func isInApplicationsFolder(_ path: String) -> Bool {
        if path.hasPrefix("/Applications/") { return true }
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        return path.hasPrefix(userApps + "/")
    }

    /// Gatekeeper path randomization mounts translocated apps under a private
    /// `AppTranslocation` path. Permissions can never persist from there.
    static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    static func shouldRelocate(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        if isTranslocated(bundlePath) { return true }
        return !isInApplicationsFolder(bundlePath)
    }

    // MARK: - Entry point

    /// Call early in launch. If AC should move to /Applications, prompts the user
    /// and — on confirmation — copies itself there, strips quarantine, and relaunches.
    /// Returns `true` if a relaunch was started (the caller should stop launching).
    @MainActor
    static func relocateIfNeeded() -> Bool {
        guard !ACTestEnvironment.isRunning else { return false }
        #if DEBUG
        return false
        #else
        let bundlePath = Bundle.main.bundlePath
        guard shouldRelocate(bundlePath: bundlePath) else { return false }

        let appName = (bundlePath as NSString).lastPathComponent
        let destination = "/Applications/\(appName)"
        let fm = FileManager.default

        let alert = NSAlert()
        alert.messageText = "Move AccountyCat to Applications?"
        alert.informativeText =
            "AccountyCat needs to live in your Applications folder for macOS permissions "
            + "(Screen Recording and Accessibility) to work reliably. It'll move itself and reopen — takes a second."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            // User declined. Translocated copies cannot function, so quitting is the
            // honest outcome; from a normal (non-translocated) path we let them proceed.
            if isTranslocated(bundlePath) {
                NSApp.terminate(nil)
                return true
            }
            return false
        }

        // Replace any existing copy so we never silently launch a stale build.
        if fm.fileExists(atPath: destination) {
            try? fm.removeItem(atPath: destination)
        }

        do {
            try fm.copyItem(atPath: bundlePath, toPath: destination)
        } catch {
            // Most likely /Applications isn't writable without admin rights. Fall back
            // to a Finder reveal with manual instructions rather than dead-ending.
            let failure = NSAlert()
            failure.messageText = "Couldn't move AccountyCat automatically"
            failure.informativeText =
                "Please drag AccountyCat into your Applications folder, then open it from there."
            failure.addButton(withTitle: "Show in Finder")
            failure.addButton(withTitle: "Quit")
            if failure.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
            }
            NSApp.terminate(nil)
            return true
        }

        stripQuarantine(at: destination)
        relaunch(at: destination)
        return true
        #endif
    }

    // MARK: - Relaunch

    /// Relaunch the app from `path` (defaults to the current bundle) and terminate
    /// the current instance. Used both after relocation and by the "Restart" button
    /// that finalizes a freshly-granted Screen Recording permission.
    @MainActor
    static func relaunch(at path: String = Bundle.main.bundlePath) {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.4; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private static func stripQuarantine(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/xattr"
        task.arguments = ["-dr", "com.apple.quarantine", path]
        try? task.run()
        task.waitUntilExit()
    }
}
