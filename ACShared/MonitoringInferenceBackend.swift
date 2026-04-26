//
//  MonitoringInferenceBackend.swift
//  ACShared
//
//  Shared between the AC app and ACInspector so the pipeline definition can
//  carry the backend selector without dragging the AC-only models into the
//  inspector target.
//

import Foundation

enum MonitoringInferenceBackend: String, Codable, CaseIterable, Sendable {
    case local
    case openRouter = "open_router"

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .openRouter:
            return "Online (OpenRouter)"
        }
    }
}
