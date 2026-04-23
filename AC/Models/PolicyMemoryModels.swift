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
        active: Bool = true
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
}

nonisolated struct PolicyMemoryOperation: Codable, Hashable, Sendable {
    var type: PolicyMemoryOperationType
    var rule: PolicyRule?
    var ruleID: String?
    var patch: PolicyRulePatch?
    var reason: String?
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
                rules.removeAll { $0.id == targetID }

            case .expireRule:
                guard let targetID = operation.ruleID ?? operation.rule?.id,
                      let index = rules.firstIndex(where: { $0.id == targetID }) else {
                    continue
                }
                rules[index].active = false
                rules[index].updatedAt = now
            }
        }

        lastUpdatedAt = now
        sortRules()
    }

    func activeRules(
        at now: Date,
        matching context: FrontmostContext? = nil
    ) -> [PolicyRule] {
        rules
            .filter { rule in
                guard rule.isActive(at: now) else { return false }
                if let context { return rule.matches(context: context) }
                return true
            }
            .sorted(by: Self.ruleSort)
    }

    func monitoringSummary(
        for context: FrontmostContext,
        usageByDay: [String: [String: TimeInterval]],
        now: Date,
        limit: Int = 6
    ) -> String {
        let rules = activeRules(at: now, matching: context).prefix(limit)
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
