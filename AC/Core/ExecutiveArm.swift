//
//  ExecutiveArm.swift
//  AC
//
//  Created by Codex on 12.04.26.
//

import AppKit
import Foundation

@MainActor
final class ExecutiveArm {
    private let showNudge: (String) -> Void
    private let showOverlay: (OverlayPresentation) -> Void
    private let hideOverlay: () -> Void

    init(
        showNudge: @escaping (String) -> Void,
        showOverlay: @escaping (OverlayPresentation) -> Void,
        hideOverlay: @escaping () -> Void
    ) {
        self.showNudge = showNudge
        self.showOverlay = showOverlay
        self.hideOverlay = hideOverlay
    }

    func perform(_ action: CompanionAction) {
        switch action {
        case .none:
            break
        case let .showNudge(message):
            showNudge(message)
        case let .showOverlay(presentation):
            showOverlay(presentation)
        }
    }

    func dismissOverlay() {
        hideOverlay()
    }

    func openRescueApp(_ target: RescueAppTarget) {
        if let applicationPath = target.applicationPath,
           FileManager.default.fileExists(atPath: applicationPath) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: applicationPath), configuration: configuration)
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
