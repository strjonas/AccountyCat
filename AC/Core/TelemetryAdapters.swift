//
//  TelemetryAdapters.swift
//  AC
//
//  Created by Codex on 13.04.26.
//

import Foundation

extension AppSwitchRecord {
    nonisolated var telemetryRecord: TelemetryAppSwitchRecord {
        TelemetryAppSwitchRecord(
            fromAppName: fromAppName,
            toAppName: toAppName,
            toWindowTitle: toWindowTitle,
            timestamp: timestamp
        )
    }
}

extension AppUsageRecord {
    nonisolated var telemetryRecord: TelemetryUsageRecord {
        TelemetryUsageRecord(appName: appName, seconds: seconds)
    }
}

extension ActionRecord {
    nonisolated var telemetrySummary: TelemetryActionSummary {
        TelemetryActionSummary(
            kind: kind.rawValue,
            message: message,
            timestamp: timestamp
        )
    }
}

extension DistractionMetadata {
    nonisolated var telemetryState: TelemetryDistractionState {
        CompanionPolicy.telemetryState(from: self)
    }
}

extension MonitoringExecutionMetadata {
    nonisolated var telemetryRecord: MonitoringExecutionMetadataRecord {
        MonitoringExecutionMetadataRecord(
            algorithmID: algorithmID,
            algorithmVersion: algorithmVersion,
            promptProfileID: promptProfileID,
            pipelineProfileID: pipelineProfileID,
            runtimeProfileID: runtimeProfileID,
            experimentArm: experimentArm
        )
    }
}

extension FrontmostContext {
    nonisolated func telemetryContext(
        idleSeconds: TimeInterval,
        recentSwitches: [AppSwitchRecord],
        perAppDurations: [AppUsageRecord],
        recentActions: [ActionRecord],
        timestamp: Date
    ) -> TelemetryContextRecord {
        TelemetryContextRecord(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            contextKey: contextKey,
            idleSeconds: idleSeconds,
            recentSwitches: recentSwitches.map(\.telemetryRecord),
            perAppDurations: perAppDurations.map(\.telemetryRecord),
            recentActions: recentActions.map(\.telemetrySummary),
            timestamp: timestamp
        )
    }
}

extension MonitoringHeuristics {
    /// Build the per-tick heuristic snapshot. `focusGoal` is the active profile's
    /// description (or the recently-ended session's goal summary) — supplying it
    /// enables the soft `titleRelatesToDeclaredFocus` signal in the prompt payload.
    /// Pass `nil` (the default) to skip that signal entirely.
    nonisolated static func telemetrySnapshot(
        for context: FrontmostContext,
        focusGoal: String? = nil
    ) -> TelemetryHeuristicSnapshot {
        let helpfulWindowTitle: Bool
        if let title = context.windowTitle {
            helpfulWindowTitle = !isUnhelpfulWindowTitle(title, appName: context.appName)
        } else {
            helpfulWindowTitle = false
        }

        return TelemetryHeuristicSnapshot(
            clearlyProductive: isClearlyProductive(bundleIdentifier: context.bundleIdentifier, appName: context.appName),
            browser: isBrowser(bundleIdentifier: context.bundleIdentifier),
            helpfulWindowTitle: helpfulWindowTitle,
            periodicVisualReason: visualCheckReason(for: context),
            titleRelatesToDeclaredFocus: titleRelatesToFocus(context.windowTitle, focusGoal: focusGoal)
        )
    }
}
