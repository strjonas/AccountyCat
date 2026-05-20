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
    private let minimizeApp: (String?) -> Void
    private let hideCompanion: () -> Void
    private let showCompanion: () -> Void

    init(
        showNudge: @escaping (String) -> Void,
        showOverlay: @escaping (OverlayPresentation) -> Void,
        hideOverlay: @escaping () -> Void,
        minimizeApp: @escaping (String?) -> Void,
        hideCompanion: @escaping () -> Void = {},
        showCompanion: @escaping () -> Void = {}
    ) {
        self.showNudge = showNudge
        self.showOverlay = showOverlay
        self.hideOverlay = hideOverlay
        self.minimizeApp = minimizeApp
        self.hideCompanion = hideCompanion
        self.showCompanion = showCompanion
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

    func hideApp(bundleIdentifier: String?) {
        minimizeApp(bundleIdentifier)
    }

    func hideCompanionPanel() {
        hideCompanion()
    }

    func showCompanionPanel() {
        showCompanion()
    }

}
