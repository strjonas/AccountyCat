//
//  LLMMonitorAlgorithm+ExplicitDirectives.swift
//  AC
//

import Foundation

extension LLMMonitorAlgorithm {
    nonisolated static func hasActiveExplicitAllowanceOverride(
        snapshot: AppSnapshot,
        now: Date,
        recentUserMessages: [String],
        freeFormMemory: String
    ) -> Bool {
        let recentDirectives = recentUserMessages.enumerated().compactMap { index, message in
            // If a caller passes plain chat text without a stamped prefix, synthesise
            // an ordering timestamp so newer chat lines still outrank older memory.
            let fallbackTimestamp = now.addingTimeInterval(-Double(max(recentUserMessages.count - index, 1)))
            return parseExplicitDirective(from: message, fallbackTimestamp: fallbackTimestamp)
        }
        let memoryDirectives = freeFormMemory
            .split(separator: "\n")
            .compactMap { parseExplicitDirective(from: String($0), fallbackTimestamp: nil) }
        let directives = recentDirectives + memoryDirectives

        let matchingAllows = directives
            .filter { $0.kind == .allow }
            .filter { $0.isActive(at: now) }
            .filter { directiveMatchesContext($0.target, snapshot: snapshot) }
            .sorted { $0.sourceTime > $1.sourceTime }
        guard let newestAllow = matchingAllows.first else { return false }

        let matchingBlocks = directives
            .filter { $0.kind == .block }
            .filter { $0.isActive(at: now) }
            .filter { directiveMatchesContext($0.target, snapshot: snapshot) }
            .sorted { $0.sourceTime > $1.sourceTime }

        guard let newestBlock = matchingBlocks.first else { return true }
        return newestAllow.sourceTime >= newestBlock.sourceTime
    }

    nonisolated private static func parseExplicitDirective(
        from line: String,
        fallbackTimestamp: Date?
    ) -> ExplicitDirective? {
        let trimmed = line.cleanedSingleLine
        let parsed = parseStampedLine(trimmed)
        let sourceTime = parsed?.timestamp ?? fallbackTimestamp
        let body = parsed?.body ?? trimmed
        guard let sourceTime else { return nil }
        let lowerBody = body.lowercased()

        if let absoluteAllow = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: " is allowed until "
        ) {
            return ExplicitDirective(
                kind: .allow,
                target: absoluteAllow.target,
                sourceTime: sourceTime,
                expiresAt: absoluteAllow.expiresAt
            )
        }
        if let absoluteOkay = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: " is okay until "
        ) {
            return ExplicitDirective(
                kind: .allow,
                target: absoluteOkay.target,
                sourceTime: sourceTime,
                expiresAt: absoluteOkay.expiresAt
            )
        }
        if let relativeAllow = parseRelativeAllowance(body: body, lowerBody: lowerBody, sourceTime: sourceTime) {
            return relativeAllow
        }
        if let simpleAllowTarget = parseSimpleAllowTarget(body: body, lowerBody: lowerBody) {
            return ExplicitDirective(
                kind: .allow,
                target: simpleAllowTarget,
                sourceTime: sourceTime,
                expiresAt: nil
            )
        }
        if let blockUntil = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: "do not allow use of ",
            trailingSeparator: " until "
        ) {
            return ExplicitDirective(
                kind: .block,
                target: blockUntil.target,
                sourceTime: sourceTime,
                expiresAt: blockUntil.expiresAt
            )
        }
        if let blockUntil = parseAbsoluteDirective(
            body: body,
            lowerBody: lowerBody,
            separator: "do not allow ",
            trailingSeparator: " until "
        ) {
            return ExplicitDirective(
                kind: .block,
                target: blockUntil.target,
                sourceTime: sourceTime,
                expiresAt: blockUntil.expiresAt
            )
        }
        if let blockToday = parseTodayBlock(body: body, lowerBody: lowerBody, sourceTime: sourceTime) {
            return blockToday
        }
        if let simpleBlockTarget = parseSimpleBlockTarget(body: body, lowerBody: lowerBody) {
            return ExplicitDirective(
                kind: .block,
                target: simpleBlockTarget,
                sourceTime: sourceTime,
                expiresAt: nil
            )
        }

        return nil
    }

    nonisolated private static func parseSimpleAllowTarget(body: String, lowerBody: String) -> String? {
        if let target = parsePrefixedTarget(
            body: body,
            lowerBody: lowerBody,
            prefixes: ["allow ", "let me use "]
        ) {
            return target
        }

        let suffixes = [" is okay", " is allowed"]
        for suffix in suffixes where lowerBody.contains(suffix) {
            guard let range = lowerBody.range(of: suffix) else { continue }
            let target = body[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }

        if let target = parseNoInterventionAllowTarget(body: body, lowerBody: lowerBody) {
            return target
        }

        return nil
    }

    nonisolated private static func parseNoInterventionAllowTarget(body: String, lowerBody: String) -> String? {
        let disturbPrefixes = [
            "do not disturb me on ",
            "don't disturb me on ",
            "dont disturb me on ",
            "do not distrub me on ",
            "don't distrub me on ",
            "dont distrub me on ",
        ]
        if let target = parsePrefixedTarget(body: body, lowerBody: lowerBody, prefixes: disturbPrefixes) {
            return target
        }

        let flagPrefixes = [
            "never again flag ",
            "never flag ",
            "do not flag ",
            "don't flag ",
            "dont flag ",
        ]
        for prefix in flagPrefixes where lowerBody.hasPrefix(prefix) {
            guard let suffixRange = lowerBody.range(of: " as a distraction"),
                  suffixRange.lowerBound > lowerBody.index(lowerBody.startIndex, offsetBy: prefix.count) else {
                continue
            }
            let startIndex = body.index(body.startIndex, offsetBy: prefix.count)
            let suffixOffset = lowerBody.distance(from: lowerBody.startIndex, to: suffixRange.lowerBound)
            let endIndex = body.index(body.startIndex, offsetBy: suffixOffset)
            let target = body[startIndex..<endIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }

        return nil
    }

    nonisolated private static func parseSimpleBlockTarget(body: String, lowerBody: String) -> String? {
        parsePrefixedTarget(
            body: body,
            lowerBody: lowerBody,
            prefixes: ["do not allow use of ", "do not allow ", "don't let me use ", "dont let me use "]
        )
    }

    nonisolated private static func parsePrefixedTarget(
        body: String,
        lowerBody: String,
        prefixes: [String]
    ) -> String? {
        for prefix in prefixes where lowerBody.hasPrefix(prefix) {
            let start = body.index(body.startIndex, offsetBy: prefix.count)
            let target = body[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return cleanedDirectiveTarget(target)
        }
        return nil
    }

    nonisolated private static func cleanedDirectiveTarget(_ text: String) -> String {
        var result = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = result.lowercased()
        for suffix in [" for now", " right now"] where lower.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }
        return result
    }

    nonisolated private static func parseStampedLine(_ line: String) -> (timestamp: Date, body: String)? {
        guard line.hasPrefix("["),
              let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let label = String(line[line.index(after: line.startIndex)..<closingBracket])
        let body = String(line[line.index(after: closingBracket)...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty,
              let timestamp = makeLocalPromptDateFormatter().date(from: label) else {
            return nil
        }
        return (timestamp, body)
    }

    nonisolated private static func parseAbsoluteDirective(
        body: String,
        lowerBody: String,
        separator: String
    ) -> (target: String, expiresAt: Date)? {
        guard let range = lowerBody.range(of: separator) else { return nil }
        let target = body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !target.isEmpty,
              let expiresAt = makeLocalPromptDateFormatter().date(from: timeText) else {
            return nil
        }
        return (target, expiresAt)
    }

    nonisolated private static func parseAbsoluteDirective(
        body: String,
        lowerBody: String,
        separator: String,
        trailingSeparator: String
    ) -> (target: String, expiresAt: Date)? {
        guard let prefixRange = lowerBody.range(of: separator),
              prefixRange.lowerBound == lowerBody.startIndex,
              let trailingRange = lowerBody.range(of: trailingSeparator),
              trailingRange.lowerBound > prefixRange.upperBound else {
            return nil
        }
        let target = body[prefixRange.upperBound..<trailingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = body[trailingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !target.isEmpty,
              let expiresAt = makeLocalPromptDateFormatter().date(from: timeText) else {
            return nil
        }
        return (target, expiresAt)
    }

    nonisolated private static func parseRelativeAllowance(
        body: String,
        lowerBody: String,
        sourceTime: Date
    ) -> ExplicitDirective? {
        if let range = lowerBody.range(of: " is okay for the next ") {
            let target = body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = lowerBody[range.upperBound...]
            guard !target.isEmpty,
                  let duration = parseDuration(from: String(remainder)) else {
                return nil
            }
            return ExplicitDirective(
                kind: .allow,
                target: target,
                sourceTime: sourceTime,
                expiresAt: sourceTime.addingTimeInterval(duration.seconds)
            )
        }

        let prefixes = ["the next ", "for the next "]
        for prefix in prefixes where lowerBody.hasPrefix(prefix) {
            let remainder = String(lowerBody.dropFirst(prefix.count))
            guard let duration = parseDuration(from: remainder),
                  let okayRange = remainder.range(of: " is okay") else {
                continue
            }
            let targetStart = remainder.index(remainder.startIndex, offsetBy: duration.offset)
            let target = String(remainder[targetStart..<okayRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return ExplicitDirective(
                kind: .allow,
                target: target,
                sourceTime: sourceTime,
                expiresAt: sourceTime.addingTimeInterval(duration.seconds)
            )
        }

        return nil
    }

    nonisolated private static func parseDuration(from text: String) -> (seconds: TimeInterval, offset: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let amount = Double(parts[0]) else {
            return nil
        }
        let unit = String(parts[1]).lowercased()
        let seconds: TimeInterval
        if unit.hasPrefix("hour") {
            seconds = amount * 60 * 60
        } else if unit.hasPrefix("minute") {
            seconds = amount * 60
        } else {
            return nil
        }
        let prefix = "\(parts[0]) \(parts[1])"
        return (seconds, prefix.count + 1)
    }

    nonisolated private static func parseTodayBlock(
        body: String,
        lowerBody: String,
        sourceTime: Date
    ) -> ExplicitDirective? {
        let prefixes = ["do not allow use of ", "do not allow "]
        let hasTodaySuffix = lowerBody.hasSuffix(" today.") || lowerBody.hasSuffix(" today")
        for prefix in prefixes where lowerBody.hasPrefix(prefix) && hasTodaySuffix {
            let suffixLength = lowerBody.hasSuffix(" today.") ? " today.".count : " today".count
            let endIndex = body.index(body.endIndex, offsetBy: -suffixLength)
            let startIndex = body.index(body.startIndex, offsetBy: prefix.count)
            guard startIndex < endIndex else { continue }
            let target = body[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            return ExplicitDirective(
                kind: .block,
                target: target,
                sourceTime: sourceTime,
                expiresAt: endOfDay(for: sourceTime)
            )
        }
        return nil
    }

    nonisolated private static func directiveMatchesContext(_ target: String, snapshot: AppSnapshot) -> Bool {
        let contextText = contextText(for: snapshot)
        let tokenSet = contextTokenSet(for: contextText)
        let aliases = targetAliases(for: target)

        for alias in aliases {
            if alias.count <= 1 {
                if tokenSet.contains(alias) {
                    return true
                }
            } else if tokenSet.contains(alias) || contextText.contains(alias) {
                return true
            }
        }

        return false
    }

    nonisolated static func contextAliases(for snapshot: AppSnapshot) -> [String] {
        let contextText = contextText(for: snapshot)
        let tokenSet = contextTokenSet(for: contextText)
        var aliases = Set(tokenSet.filter { $0.count > 2 })

        if let host = snapshot.bundleIdentifier?.split(separator: ".").last {
            aliases.insert(String(host).lowercased())
        }
        if let windowTitle = snapshot.windowTitle {
            aliases.formUnion(targetAliases(for: windowTitle))
        }
        aliases.formUnion(targetAliases(for: snapshot.appName))

        return Array(aliases.filter { !$0.isEmpty })
    }

    nonisolated private static func contextText(for snapshot: AppSnapshot) -> String {
        [
            snapshot.appName,
            snapshot.windowTitle ?? "",
            snapshot.bundleIdentifier ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
    }

    nonisolated private static func contextTokenSet(for contextText: String) -> Set<String> {
        Set(
            contextText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    nonisolated private static func targetAliases(for target: String) -> [String] {
        let lowered = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = lowered.replacingOccurrences(
            of: #"[^a-z0-9.]+"#,
            with: " ",
            options: .regularExpression
        )
        let parts = sanitized.split(separator: " ").map(String.init)
        var aliases = Set(parts)

        if let domain = parts.first(where: { $0.contains(".") }),
           let root = domain.split(separator: ".").first {
            aliases.insert(String(root))
        }
        if !sanitized.isEmpty {
            aliases.insert(sanitized.replacingOccurrences(of: " ", with: ""))
        }
        return Array(aliases.filter { !$0.isEmpty })
    }

    nonisolated private static func endOfDay(for date: Date) -> Date? {
        let calendar = Calendar.current
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return startOfNextDay.addingTimeInterval(-60)
    }

    nonisolated private static func makeLocalPromptDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

private struct ExplicitDirective: Sendable {
    nonisolated enum Kind: Sendable {
        case allow
        case block
    }

    var kind: Kind
    var target: String
    var sourceTime: Date
    var expiresAt: Date?

    nonisolated func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt >= now
    }
}
}
