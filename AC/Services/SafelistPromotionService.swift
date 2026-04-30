//
//  SafelistPromotionService.swift
//  AC
//
//  Watches focused-observation history per app/title-context and, when an app
//  has been seen as focused enough times, asks the LLM (one cheap text-only
//  call) whether it's plausibly always-productive. On approval, an `allow`
//  PolicyRule with a graduated TTL is emitted so the existing fast-path in
//  LLMMonitorAlgorithm.evaluationPlan(...) skips evaluation for that
//  context until expiry.
//

import Foundation

enum SafelistPromotionTier: String, Sendable {
    case probationary
    case trusted
    case rePromotion = "re_promotion"

    /// TTL for the auto-allow rule. Probationary stays short to limit blast
    /// radius from a wrong call; trusted/re-promotion ride the longer 7-day
    /// window because the user has already demonstrated repeat focused use.
    var ttl: TimeInterval {
        switch self {
        case .probationary: return 24 * 60 * 60
        case .trusted, .rePromotion: return 7 * 24 * 60 * 60
        }
    }
}

enum SafelistPromotionEligibility: Equatable, Sendable {
    case ineligible(reason: String)
    case eligible(tier: SafelistPromotionTier)
}

struct SafelistObservationContext: Sendable {
    var fingerprint: String
    var appName: String
    var bundleIdentifier: String?
    var titleSignature: String?
    var isBrowser: Bool
    var requiresTitleScope: Bool
    var dayKey: String
}

enum SafelistPromotionPolicy {
    /// Throttle re-attempts so a single LLM denial doesn't spam the model.
    static let promotionAttemptCooldown: TimeInterval = 6 * 60 * 60

    /// Build the fingerprint that keys both `focusedObservations` and the auto-allow rule.
    /// Browsers and title-scoped native apps always key off the exact current title so a future
    /// title change invalidates the allow automatically.
    static func makeContext(
        from frontmost: FrontmostContext,
        isBrowser: Bool,
        now: Date
    ) -> SafelistObservationContext? {
        if isBrowser {
            guard
                let bundleID = frontmost.bundleIdentifier,
                let signature = BrowserTitleSignature.derive(from: frontmost.windowTitle)
            else {
                return nil
            }
            return SafelistObservationContext(
                fingerprint: "\(bundleID)::\(signature)",
                appName: frontmost.appName,
                bundleIdentifier: bundleID,
                titleSignature: signature,
                isBrowser: true,
                requiresTitleScope: true,
                dayKey: now.acDayKey
            )
        } else {
            if let bundleID = frontmost.bundleIdentifier,
               MonitoringHeuristics.titleScopedBundleIdentifiers.contains(bundleID) {
                guard let title = frontmost.windowTitle?.cleanedSingleLine,
                      !title.isEmpty,
                      !MonitoringHeuristics.isUnhelpfulWindowTitle(title, appName: frontmost.appName) else {
                    return nil
                }
                let signature = String(title.prefix(120))
                return SafelistObservationContext(
                    fingerprint: "\(bundleID)::\(signature)",
                    appName: frontmost.appName,
                    bundleIdentifier: bundleID,
                    titleSignature: signature,
                    isBrowser: false,
                    requiresTitleScope: true,
                    dayKey: now.acDayKey
                )
            }

            let id = frontmost.bundleIdentifier ?? frontmost.appName
            guard !id.isEmpty else { return nil }
            return SafelistObservationContext(
                fingerprint: id,
                appName: frontmost.appName,
                bundleIdentifier: frontmost.bundleIdentifier,
                titleSignature: nil,
                isBrowser: false,
                requiresTitleScope: false,
                dayKey: now.acDayKey
            )
        }
    }

    /// Mutates `stat` to register a new focused observation.
    static func recordFocused(
        stat: inout FocusedObservationStat,
        windowTitle: String?,
        now: Date,
        dayKey: String
    ) {
        stat.focusedCount += 1
        stat.lastSeenAt = now
        if !stat.distinctDayKeys.contains(dayKey) {
            stat.distinctDayKeys.append(dayKey)
            if stat.distinctDayKeys.count > 14 {
                stat.distinctDayKeys.removeFirst(stat.distinctDayKeys.count - 14)
            }
        }
        if let title = windowTitle?.cleanedSingleLine, !title.isEmpty {
            let truncated = String(title.prefix(120))
            stat.sampleWindowTitles.removeAll { $0 == truncated }
            stat.sampleWindowTitles.insert(truncated, at: 0)
            if stat.sampleWindowTitles.count > 3 {
                stat.sampleWindowTitles = Array(stat.sampleWindowTitles.prefix(3))
            }
        }
    }

    /// Decide whether `stat` qualifies for promotion right now.
    static func eligibility(
        for stat: FocusedObservationStat,
        policyMemory: PolicyMemory,
        context: FrontmostContext,
        now: Date
    ) -> SafelistPromotionEligibility {
        if stat.distractedCount > 0 {
            return .ineligible(reason: "distracted_history")
        }

        if let attempt = stat.promotionAttemptedAt,
           now.timeIntervalSince(attempt) < promotionAttemptCooldown {
            return .ineligible(reason: "throttled")
        }

        let activeRules = policyMemory.activeRules(at: now, matching: context)
        if activeRules.contains(where: { $0.kind == .disallow || $0.kind == .discourage || $0.kind == .limit }) {
            return .ineligible(reason: "user_restriction_active")
        }
        if activeRules.contains(where: { $0.kind == .allow }) {
            return .ineligible(reason: "already_allowed")
        }

        let prior = stat.previousAutoAllowOutcome
        if prior == .expiredClean {
            if stat.focusedCount >= 6, stat.distinctDayCount >= 2 {
                return .eligible(tier: .trusted)
            }
            if stat.focusedCount >= 2 {
                return .eligible(tier: .rePromotion)
            }
            return .ineligible(reason: "needs_more_observations_after_clean_expiry")
        }

        if prior == nil, stat.focusedCount >= 2 {
            return .eligible(tier: .probationary)
        }

        return .ineligible(reason: "below_threshold")
    }

    /// Build the rule the safelist appeal will emit on approval. Browsers and title-scoped apps
    /// MUST scope by `titleContains`; they are never safe at the whole-app level.
    static func buildRule(
        from envelope: MonitoringSafelistAppealEnvelope,
        observation: SafelistObservationContext,
        tier: SafelistPromotionTier,
        now: Date
    ) -> PolicyRule? {
        guard envelope.approve else { return nil }

        var scope = PolicyRuleScope()
        switch envelope.scopeKind {
        case .bundle:
            if observation.isBrowser || observation.requiresTitleScope { return nil }
            scope.bundleIdentifier = observation.bundleIdentifier
            scope.appName = observation.bundleIdentifier == nil ? observation.appName : nil
        case .titlePattern:
            if observation.requiresTitleScope, let signature = observation.titleSignature, !signature.isEmpty {
                scope.titleContains = [signature]
                if let bundleIdentifier = observation.bundleIdentifier {
                    scope.bundleIdentifier = bundleIdentifier
                }
            } else if let pattern = envelope.titlePattern?.cleanedSingleLine, !pattern.isEmpty {
                scope.titleContains = [pattern]
                if let bundleIdentifier = observation.bundleIdentifier {
                    scope.bundleIdentifier = bundleIdentifier
                } else if observation.isBrowser {
                    scope.bundleIdentifier = observation.bundleIdentifier
                }
            } else if let signature = observation.titleSignature, !signature.isEmpty {
                scope.titleContains = [signature]
                if let bundleIdentifier = observation.bundleIdentifier {
                    scope.bundleIdentifier = bundleIdentifier
                }
            } else {
                return nil
            }
        }

        var schedule = PolicyRuleSchedule()
        schedule.expiresAt = now.addingTimeInterval(tier.ttl)

        let summary = (envelope.summary?.cleanedSingleLine).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Auto-safelisted \(observation.appName) — \(tier.rawValue)"

        return PolicyRule(
            kind: .allow,
            summary: summary,
            source: .system,
            createdAt: now,
            updatedAt: now,
            priority: 30,
            scope: scope,
            schedule: schedule,
            active: true
        )
    }
}

/// Performs the cheap text-only LLM appeal that confirms a promotion.
protocol SafelistAppealEvaluating: Sendable {
    func runAppeal(
        observation: SafelistObservationContext,
        sampleWindowTitles: [String],
        focusedCount: Int,
        distinctDays: Int,
        goals: String,
        freeFormMemory: String,
        configuration: MonitoringConfiguration,
        runtimeOverride: String?,
        screenshotPath: String?
    ) async -> MonitoringSafelistAppealEnvelope?
}

actor SafelistAppealService: SafelistAppealEvaluating {
    private let runtime: LocalModelRuntime
    private let onlineModelService: any OnlineModelServing

    init(runtime: LocalModelRuntime, onlineModelService: any OnlineModelServing) {
        self.runtime = runtime
        self.onlineModelService = onlineModelService
    }

    func runAppeal(
        observation: SafelistObservationContext,
        sampleWindowTitles: [String],
        focusedCount: Int,
        distinctDays: Int,
        goals: String,
        freeFormMemory: String,
        configuration: MonitoringConfiguration,
        runtimeOverride: String?,
        screenshotPath: String?
    ) async -> MonitoringSafelistAppealEnvelope? {
        let payload = MonitoringSafelistAppealPromptPayload(
            appName: observation.appName,
            bundleIdentifier: observation.bundleIdentifier,
            sampleWindowTitles: sampleWindowTitles,
            goals: goals,
            freeFormMemory: freeFormMemory,
            focusedCount: focusedCount,
            distinctDays: distinctDays,
            isBrowser: observation.isBrowser,
            requiresTitleScope: observation.requiresTitleScope,
            screenshotIncluded: screenshotPath != nil
        )
        let payloadJSON = MonitoringLLMClient.encodePayload(payload)
        let systemPrompt = PromptCatalog.loadPolicySystemPrompt(stage: .safelistAppeal)
        let userPrompt = PromptCatalog.renderPolicyUserPrompt(
            stage: .safelistAppeal,
            payloadJSON: payloadJSON
        )
        let runtimeProfile = LLMPolicyCatalog.runtimeProfile(id: configuration.runtimeProfileID)
        let options = runtimeProfile.options(for: .safelistAppeal)

        let output: RuntimeProcessOutput
        do {
            if configuration.usesOnlineInference {
                output = try await onlineModelService.runInference(
                    OnlineModelRequest(
                        modelIdentifier: configuration.onlineModelIdentifier,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        imagePath: screenshotPath,
                        options: options
                    )
                )
            } else if let screenshotPath {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                output = try await runtime.runVisionInference(
                    runtimePath: runtimePath,
                    snapshotPath: screenshotPath,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: options
                )
            } else {
                let runtimePath = RuntimeSetupService.normalizedRuntimePath(from: runtimeOverride)
                guard FileManager.default.isExecutableFile(atPath: runtimePath) else { return nil }
                output = try await runtime.runTextInference(
                    runtimePath: runtimePath,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    options: options
                )
            }
        } catch {
            await ActivityLogService.shared.append(
                category: "safelist-appeal-error",
                message: error.localizedDescription
            )
            return nil
        }

        return StructuredOutputJSON.decode(
            MonitoringSafelistAppealEnvelope.self,
            from: output.stdout + "\n" + output.stderr
        )
    }
}
