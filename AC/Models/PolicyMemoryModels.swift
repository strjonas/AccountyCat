//
//  PolicyMemoryModels.swift
//  AC
//

import Foundation

nonisolated enum PolicyRuleKind: String, Codable, CaseIterable, Sendable {
    case allow
    case discourage
    case disallow
    case limit
    case tonePreference = "tone_preference"
}

nonisolated extension PolicyRule {
    var isAutoSafelistRule: Bool {
        kind == .allow && source == .system
    }

    var safelistMemoryScopeDescription: String {
        var parts: [String] = []
        if let bundleIdentifier = scope.bundleIdentifier, !bundleIdentifier.isEmpty {
            parts.append(bundleIdentifier)
        } else if let appName = scope.appName, !appName.isEmpty {
            parts.append(appName)
        } else {
            parts.append(summary)
        }
        if !scope.titleContains.isEmpty {
            parts.append("title contains \(scope.titleContains.joined(separator: ", "))")
        }
        return parts.joined(separator: " / ")
    }
}

nonisolated enum PolicyRuleSource: String, Codable, CaseIterable, Sendable {
    case userChat = "user_chat"
    case explicitFeedback = "explicit_feedback"
    case implicitFeedback = "implicit_feedback"
    case appeal
    case system
}

nonisolated enum PolicyTonePreference: String, Codable, CaseIterable, Sendable {
    case direct
    case supportive
    case playful
    case calm
}

nonisolated struct PolicyRuleScope: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var appName: String?
    var titleContains: [String] = []
}

nonisolated struct PolicyRuleSchedule: Codable, Hashable, Sendable {
    var startHour: Int?
    var endHour: Int?
    var weekdays: [Int] = []
    var expiresAt: Date?
}

nonisolated struct PolicyRule: Codable, Hashable, Identifiable, Sendable {
    /// Sentinel id of the always-present default profile.
    nonisolated static let defaultProfileID: String = "general"

    var id: String
    var kind: PolicyRuleKind
    var summary: String
    var source: PolicyRuleSource
    var createdAt: Date
    var updatedAt: Date
    var priority: Int
    var scope: PolicyRuleScope
    var schedule: PolicyRuleSchedule
    var allowedTopics: [String]
    var disallowedTopics: [String]
    var maxMinutesPerDay: Int?
    var tonePreference: PolicyTonePreference?
    var active: Bool
    /// When true, AC will not autonomously modify or delete this rule.
    var isLocked: Bool
    /// Profile this rule is scoped to. `nil` means global — the rule applies across all
    /// profiles. Non-nil scopes the rule to a single profile (e.g. "while coding, don't let
    /// me browse HN"). Legacy rules with `"general"` decode as global.
    var profileID: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, summary, source, createdAt, updatedAt, priority
        case scope, schedule, allowedTopics, disallowedTopics
        case maxMinutesPerDay, tonePreference, active, isLocked, profileID
    }

    init(
        id: String = UUID().uuidString,
        kind: PolicyRuleKind,
        summary: String,
        source: PolicyRuleSource,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        priority: Int = 50,
        scope: PolicyRuleScope = PolicyRuleScope(),
        schedule: PolicyRuleSchedule = PolicyRuleSchedule(),
        allowedTopics: [String] = [],
        disallowedTopics: [String] = [],
        maxMinutesPerDay: Int? = nil,
        tonePreference: PolicyTonePreference? = nil,
        active: Bool = true,
        isLocked: Bool = false,
        profileID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.priority = priority
        self.scope = scope
        self.schedule = schedule
        self.allowedTopics = allowedTopics
        self.disallowedTopics = disallowedTopics
        self.maxMinutesPerDay = maxMinutesPerDay
        self.tonePreference = tonePreference
        self.active = active
        self.isLocked = isLocked
        self.profileID = profileID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(PolicyRuleKind.self, forKey: .kind)
        summary = try c.decode(String.self, forKey: .summary)
        source = try c.decode(PolicyRuleSource.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        priority = try c.decode(Int.self, forKey: .priority)
        scope = try c.decode(PolicyRuleScope.self, forKey: .scope)
        schedule = try c.decode(PolicyRuleSchedule.self, forKey: .schedule)
        allowedTopics = try c.decode([String].self, forKey: .allowedTopics)
        disallowedTopics = try c.decode([String].self, forKey: .disallowedTopics)
        maxMinutesPerDay = try c.decodeIfPresent(Int.self, forKey: .maxMinutesPerDay)
        tonePreference = try c.decodeIfPresent(PolicyTonePreference.self, forKey: .tonePreference)
        active = try c.decode(Bool.self, forKey: .active)
        isLocked = (try? c.decode(Bool.self, forKey: .isLocked)) ?? false
        let raw = try? c.decode(String.self, forKey: .profileID)
        profileID = raw.flatMap { $0 == PolicyRule.defaultProfileID ? nil : $0 }
    }

    func isActive(at now: Date, calendar: Calendar = .current) -> Bool {
        guard active else { return false }
        if let expiresAt = schedule.expiresAt, now > expiresAt {
            return false
        }
        if !schedule.weekdays.isEmpty {
            let weekday = calendar.component(.weekday, from: now)
            guard schedule.weekdays.contains(weekday) else { return false }
        }
        if let startHour = schedule.startHour, let endHour = schedule.endHour {
            let hour = calendar.component(.hour, from: now)
            if startHour <= endHour {
                guard (startHour...endHour).contains(hour) else { return false }
            } else {
                guard hour >= startHour || hour <= endHour else { return false }
            }
        }
        return true
    }

    func matches(context: FrontmostContext) -> Bool {
        if let bundleIdentifier = scope.bundleIdentifier,
           context.bundleIdentifier != bundleIdentifier {
            return false
        }
        if let appName = scope.appName,
           context.appName.cleanedSingleLine.caseInsensitiveCompare(appName.cleanedSingleLine) != .orderedSame {
            return false
        }
        if !scope.titleContains.isEmpty {
            let normalizedTitle = context.windowTitle?.lowercased() ?? ""
            guard scope.titleContains.contains(where: { normalizedTitle.contains($0.lowercased()) }) else {
                return false
            }
        }
        return true
    }
}

nonisolated struct PolicyRulePatch: Codable, Hashable, Sendable {
    var summary: String?
    var priority: Int?
    var scope: PolicyRuleScope?
    var schedule: PolicyRuleSchedule?
    var allowedTopics: [String]?
    var disallowedTopics: [String]?
    var maxMinutesPerDay: Int?
    var tonePreference: PolicyTonePreference?
    var active: Bool?
}

nonisolated enum PolicyMemoryOperationType: String, Codable, CaseIterable, Sendable {
    case addRule = "add_rule"
    case updateRule = "update_rule"
    case removeRule = "remove_rule"
    case expireRule = "expire_rule"
    /// Switch to an existing focus profile by id. Optional `profileDurationMinutes` overrides
    /// the default 90 minutes. Routed through `AppController` rather than mutating `rules`.
    case activateProfile = "activate_profile"
    /// Create a new named focus profile and activate it. Requires `profileName`. Optional
    /// `profileDescription` and `profileDurationMinutes`. Subject to the LRU cap.
    case createAndActivateProfile = "create_and_activate_profile"
    /// End the active named profile and switch back to the default. No fields required.
    case endActiveProfile = "end_active_profile"
}

nonisolated struct PolicyMemoryOperation: Codable, Hashable, Sendable {
    var type: PolicyMemoryOperationType
    var rule: PolicyRule?
    var ruleID: String?
    var patch: PolicyRulePatch?
    var reason: String?
    /// Profile-op fields (only used by `activateProfile` / `createAndActivateProfile`).
    var profileID: String?
    var profileName: String?
    var profileDescription: String?
    var profileDurationMinutes: Int?

    private enum CodingKeys: String, CodingKey {
        case type, rule, ruleID, patch, reason
        case profileID, profileName, profileDescription, profileDurationMinutes
    }

    init(
        type: PolicyMemoryOperationType,
        rule: PolicyRule? = nil,
        ruleID: String? = nil,
        patch: PolicyRulePatch? = nil,
        reason: String? = nil,
        profileID: String? = nil,
        profileName: String? = nil,
        profileDescription: String? = nil,
        profileDurationMinutes: Int? = nil
    ) {
        self.type = type
        self.rule = rule
        self.ruleID = ruleID
        self.patch = patch
        self.reason = reason
        self.profileID = profileID
        self.profileName = profileName
        self.profileDescription = profileDescription
        self.profileDurationMinutes = profileDurationMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(PolicyMemoryOperationType.self, forKey: .type)
        rule = try c.decodeIfPresent(PolicyRule.self, forKey: .rule)
        ruleID = try c.decodeIfPresent(String.self, forKey: .ruleID)
        patch = try c.decodeIfPresent(PolicyRulePatch.self, forKey: .patch)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        profileDescription = try c.decodeIfPresent(String.self, forKey: .profileDescription)
        profileDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .profileDurationMinutes)
    }
}

nonisolated struct PolicyMemoryUpdateResponse: Codable, Hashable, Sendable {
    var operations: [PolicyMemoryOperation]

    static let empty = PolicyMemoryUpdateResponse(operations: [])
}

nonisolated struct PolicyMemory: Codable, Hashable, Sendable {
    var rules: [PolicyRule] = []
    var tonePreference: PolicyTonePreference?
    var lastUpdatedAt: Date?

    mutating func expireRules(at now: Date) {
        rules = rules.map { rule in
            guard rule.active, let expiresAt = rule.schedule.expiresAt, expiresAt <= now else {
                return rule
            }
            var expired = rule
            expired.active = false
            expired.updatedAt = now
            return expired
        }
    }

    mutating func apply(
        _ update: PolicyMemoryUpdateResponse,
        now: Date = Date()
    ) {
        guard !update.operations.isEmpty else { return }

        for operation in update.operations {
            switch operation.type {
            case .addRule:
                guard let rule = operation.rule else { continue }
                if let existingIndex = rules.firstIndex(where: { $0.id == rule.id }) {
                    guard !rules[existingIndex].isLocked else { continue }
                    rules[existingIndex] = rule
                } else {
                    rules.append(rule)
                }
                if let tonePreference = rule.tonePreference {
                    self.tonePreference = tonePreference
                }

            case .updateRule:
                guard let targetID = operation.ruleID ?? operation.rule?.id,
                      let index = rules.firstIndex(where: { $0.id == targetID }) else {
                    continue
                }
                guard !rules[index].isLocked else { continue }
                if let replacement = operation.rule {
                    rules[index] = replacement
                    if let tonePreference = replacement.tonePreference {
                        self.tonePreference = tonePreference
                    }
                    continue
                }
                guard let patch = operation.patch else { continue }
                var updated = rules[index]
                if let summary = patch.summary { updated.summary = summary }
                if let priority = patch.priority { updated.priority = priority }
                if let scope = patch.scope { updated.scope = scope }
                if let schedule = patch.schedule { updated.schedule = schedule }
                if let allowedTopics = patch.allowedTopics { updated.allowedTopics = allowedTopics }
                if let disallowedTopics = patch.disallowedTopics { updated.disallowedTopics = disallowedTopics }
                if let maxMinutesPerDay = patch.maxMinutesPerDay { updated.maxMinutesPerDay = maxMinutesPerDay }
                if let tonePreference = patch.tonePreference {
                    updated.tonePreference = tonePreference
                    self.tonePreference = tonePreference
                }
                if let active = patch.active { updated.active = active }
                updated.updatedAt = now
                rules[index] = updated

            case .removeRule:
                guard let targetID = operation.ruleID ?? operation.rule?.id else { continue }
                rules.removeAll { $0.id == targetID && !$0.isLocked }

            case .expireRule:
                guard let targetID = operation.ruleID ?? operation.rule?.id,
                      let index = rules.firstIndex(where: { $0.id == targetID }) else {
                    continue
                }
                guard !rules[index].isLocked else { continue }
                rules[index].active = false
                rules[index].updatedAt = now

            case .activateProfile, .createAndActivateProfile, .endActiveProfile:
                // Handled at the controller layer (AppController.applyProfileOperations).
                continue
            }
        }

        lastUpdatedAt = now
        sortRules()
    }

    func activeRules(
        at now: Date,
        matching context: FrontmostContext? = nil,
        profileID: String? = nil
    ) -> [PolicyRule] {
        rules
            .filter { rule in
                guard rule.isActive(at: now) else { return false }
                if let profileID {
                    // Include global rules (nil) + rules scoped to the requested profile.
                    guard rule.profileID == nil || rule.profileID == profileID else {
                        return false
                    }
                }
                if let context { return rule.matches(context: context) }
                return true
            }
            .sorted(by: Self.ruleSort)
    }

    func monitoringSummary(
        for context: FrontmostContext,
        usageByDay: [String: [String: TimeInterval]],
        now: Date,
        limit: Int = 6,
        profileID: String? = nil
    ) -> String {
        let rules = activeRules(at: now, matching: context, profileID: profileID).prefix(limit)
        var lines: [String] = []

        if let tonePreference {
            lines.append("Preferred tone: \(tonePreference.rawValue)")
        }

        for rule in rules {
            var segments = [rule.summary]
            if let maxMinutesPerDay = rule.maxMinutesPerDay {
                let usedMinutes = Int((usageByDay[now.acDayKey]?[context.appName] ?? 0) / 60)
                segments.append("limit \(maxMinutesPerDay)m/day, used \(usedMinutes)m today")
            }
            if !rule.allowedTopics.isEmpty {
                segments.append("allowed: \(rule.allowedTopics.joined(separator: ", "))")
            }
            if !rule.disallowedTopics.isEmpty {
                segments.append("avoid: \(rule.disallowedTopics.joined(separator: ", "))")
            }
            if let expiresAt = rule.schedule.expiresAt {
                segments.append("until \(PromptTimestampFormatting.absoluteLabel(for: expiresAt))")
            }
            lines.append("• " + segments.joined(separator: " — "))
        }

        return lines.joined(separator: "\n")
    }

    func chatSummary(
        now: Date,
        limit: Int = 8,
        profileID: String? = nil
    ) -> String {
        let activeRules = activeRules(at: now, profileID: profileID).prefix(limit)
        var lines: [String] = []

        if let tonePreference {
            lines.append("Preferred tone: \(tonePreference.rawValue)")
        }

        for rule in activeRules {
            var segments = ["\(rule.kind.rawValue): \(rule.summary)"]
            if let appName = rule.scope.appName, !appName.isEmpty {
                segments.append("app \(appName)")
            }
            if !rule.scope.titleContains.isEmpty {
                segments.append("title contains \(rule.scope.titleContains.joined(separator: ", "))")
            }
            if let expiresAt = rule.schedule.expiresAt {
                segments.append("until \(PromptTimestampFormatting.absoluteLabel(for: expiresAt))")
            }
            if rule.isLocked {
                segments.append("fixed")
            }
            lines.append("• " + segments.joined(separator: " — "))
        }

        return lines.joined(separator: "\n")
    }

    private mutating func sortRules() {
        rules.sort(by: Self.ruleSort)
    }

    nonisolated private static func ruleSort(_ lhs: PolicyRule, _ rhs: PolicyRule) -> Bool {
        if lhs.priority == rhs.priority {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.priority > rhs.priority
    }
}
