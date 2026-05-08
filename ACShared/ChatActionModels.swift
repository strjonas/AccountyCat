//
//  ChatActionModels.swift
//  ACShared
//
//  Minimal LLM-facing action contracts for AccountyCat chat.
//

import Foundation

nonisolated enum CompanionChatWorkflow: String, Codable, Hashable, Sendable {
    /// Capable online models may return small executable action payloads directly
    /// with the user-facing chat reply.
    case direct
    /// Smaller/local models only return action hints. Dedicated low-temperature
    /// executor calls resolve each hint into an executable action.
    case staged
}

nonisolated enum CompanionChatActionKind: String, Codable, Hashable, Sendable {
    case profile
    case memory
    case focusPolicy = "focus_policy"
}

nonisolated struct CompanionChatActionTarget: Codable, Hashable, Sendable {
    var type: String
    var value: String?

    init(type: String, value: String? = nil) {
        self.type = type
        self.value = value
    }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self.type = string
            self.value = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        self.value = try c.decodeIfPresent(String.self, forKey: .value)
            ?? (try c.decodeIfPresent(String.self, forKey: .name))
            ?? (try c.decodeIfPresent(String.self, forKey: .text))
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, name, text
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(value, forKey: .value)
    }
}

nonisolated struct CompanionChatAction: Codable, Hashable, Sendable {
    var kind: CompanionChatActionKind
    /// Staged workflow hint. In direct workflow this may still be present when
    /// the model knows an action is needed but does not have enough fields.
    var instruction: String?
    /// Minimal executable fields used by direct workflow and executor outputs.
    var intent: String?
    var profileID: String?
    var profileName: String?
    var profileDescription: String?
    var durationMinutes: Int?
    var reason: String?
    var text: String?
    var scope: String?
    var target: CompanionChatActionTarget?
    var duration: String?
    var locked: Bool?

    init(
        kind: CompanionChatActionKind,
        instruction: String? = nil,
        intent: String? = nil,
        profileID: String? = nil,
        profileName: String? = nil,
        profileDescription: String? = nil,
        durationMinutes: Int? = nil,
        reason: String? = nil,
        text: String? = nil,
        scope: String? = nil,
        target: CompanionChatActionTarget? = nil,
        duration: String? = nil,
        locked: Bool? = nil
    ) {
        self.kind = kind
        self.instruction = instruction
        self.intent = intent
        self.profileID = profileID
        self.profileName = profileName
        self.profileDescription = profileDescription
        self.durationMinutes = durationMinutes
        self.reason = reason
        self.text = text
        self.scope = scope
        self.target = target
        self.duration = duration
        self.locked = locked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(CompanionChatActionKind.self, forKey: .kind)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
            ?? (try c.decodeIfPresent(String.self, forKey: .profile_id))
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
            ?? (try c.decodeIfPresent(String.self, forKey: .profile_name))
        profileDescription = try c.decodeIfPresent(String.self, forKey: .profileDescription)
            ?? (try c.decodeIfPresent(String.self, forKey: .profile_description))
        durationMinutes = Self.decodeFlexibleInt(c, .durationMinutes)
            ?? Self.decodeFlexibleInt(c, .duration_minutes)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        target = try c.decodeIfPresent(CompanionChatActionTarget.self, forKey: .target)
        duration = try c.decodeIfPresent(String.self, forKey: .duration)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, instruction, intent, profileID, profile_id, profileName, profile_name
        case profileDescription, profile_description, durationMinutes, duration_minutes
        case reason, text, scope, target, duration, locked
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(instruction, forKey: .instruction)
        try c.encodeIfPresent(intent, forKey: .intent)
        try c.encodeIfPresent(profileID, forKey: .profileID)
        try c.encodeIfPresent(profileName, forKey: .profileName)
        try c.encodeIfPresent(profileDescription, forKey: .profileDescription)
        try c.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(locked, forKey: .locked)
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

nonisolated struct CompanionChatActionResolutionPayload: Codable, Hashable, Sendable {
    var action: CompanionChatAction
}
