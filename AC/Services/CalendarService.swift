//
//  CalendarService.swift
//  AC
//
//  Read-only EventKit wrapper used by the "Calendar Intelligence" feature.
//
//  Everything here is local to the device. EventKit returns events from any
//  calendar the user already has in macOS Calendar.app — that includes
//  Google/iCloud/Exchange/CalDAV accounts added via System Settings.
//  AC never makes a network call itself; sync happens at the OS level.
//

import EventKit
import Foundation

/// Lightweight description of a single user calendar — used to drive the
/// multi-select picker in Settings without leaking raw EventKit types.
struct ACCalendarInfo: Identifiable, Hashable, Sendable {
    var id: String            // EKCalendar.calendarIdentifier — stable per-device
    var title: String
    var sourceTitle: String   // "iCloud", "Google", etc.
    var colorHex: String?     // convenience for future UI polish (not used yet)
    var allowsModifications: Bool
}

/// EventKit-backed calendar service. Actor-isolated because EKEventStore is not
/// thread-safe for concurrent access from multiple callers.
actor CalendarService {
    static let shared = CalendarService()

    private static let googleTasksEditDisclaimerPattern =
        #"Changes made to the title, description, or attachments will not be saved\.\s*To make edits, please go to:\s*https?://tasks\.google\.com/\S+"#

    private let store = EKEventStore()

    // Small cache so repeated calls within a monitor tick don't hit EventKit.
    private var cachedContextAt: Date?
    private var cachedContext: String?
    private static let cacheTTL: TimeInterval = 15

    // MARK: - Authorization

    /// Current authorization status for reading events. Matches the enum
    /// returned by EventKit so callers can map to `PermissionState`.
    nonisolated static func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Prompt the user for read access. Uses the macOS 14+ full-access API
    /// when available and falls back to the legacy API on older systems.
    /// AC only reads events, but EventKit doesn't offer a true "read-only"
    /// grant — full access is the minimum that lets us enumerate events.
    @discardableResult
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Calendar enumeration

    /// All event calendars the user has configured. Sorted by source + title
    /// so Google / iCloud / Exchange calendars group naturally in the picker.
    func availableCalendars() -> [ACCalendarInfo] {
        let calendars = store.calendars(for: .event)
        return calendars
            .map { cal in
                ACCalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceTitle: cal.source.title,
                    colorHex: nil,
                    allowsModifications: cal.allowsContentModifications
                )
            }
            .sorted { lhs, rhs in
                if lhs.sourceTitle == rhs.sourceTitle { return lhs.title < rhs.title }
                return lhs.sourceTitle < rhs.sourceTitle
            }
    }

    // MARK: - Current event lookup

    /// Returns a short, prompt-safe string describing the event the user is
    /// currently in, or nil if there's no ongoing event. Honours the user's
    /// multi-select picker: if `enabledCalendarIdentifiers` is empty we treat
    /// that as "all enabled calendars" (the default for fresh opt-in); if it
    /// has entries we filter to just those.
    ///
    /// The string format is intentionally compact — the decision prompt is
    /// token-sensitive and the calendar is a soft hint, not ground truth.
    func currentEventContext(
        now: Date = Date(),
        enabledCalendarIdentifiers: Set<String> = []
    ) -> String? {
        if let cachedAt = cachedContextAt,
           now.timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedContext
        }

        let status = Self.authorizationStatus()
        let authorized: Bool
        if #available(macOS 14.0, *) {
            authorized = status == .fullAccess
        } else {
            authorized = status == .authorized
        }
        guard authorized else {
            cachedContextAt = now
            cachedContext = nil
            return nil
        }

        let allCalendars = store.calendars(for: .event)
        let filtered: [EKCalendar]
        if enabledCalendarIdentifiers.isEmpty {
            filtered = allCalendars
        } else {
            filtered = allCalendars.filter { enabledCalendarIdentifiers.contains($0.calendarIdentifier) }
        }
        guard !filtered.isEmpty else {
            cachedContextAt = now
            cachedContext = nil
            return nil
        }

        // Narrow window around `now` to keep the predicate cheap. We only care
        // about the event that is *currently* happening; a tight ±12h window
        // comfortably covers DST edges and long meetings without pulling the
        // whole week.
        let windowStart = now.addingTimeInterval(-12 * 60 * 60)
        let windowEnd = now.addingTimeInterval(12 * 60 * 60)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: filtered
        )

        let events = store.events(matching: predicate)
        let ongoing = events
            .filter { !$0.isAllDay }
            .filter { $0.startDate <= now && $0.endDate > now }
            // Prefer the most-recently-started event if several overlap,
            // because that's almost always the "foreground" meeting.
            .sorted { $0.startDate > $1.startDate }

        guard let event = ongoing.first else {
            cachedContextAt = now
            cachedContext = nil
            return nil
        }

        let title = (event.title ?? "Untitled event")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = Self.sanitizeNotesForPrompt(event.notes ?? "")

        // Keep the rendered string small and single-line — it sits inside a
        // JSON payload that the local model parses each monitor tick.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        let endLabel = formatter.string(from: event.endDate)

        var parts: [String] = ["\(title) (ends \(endLabel))"]
        if !notes.isEmpty {
            let capped = notes.count > 160
                ? String(notes.prefix(160)) + "…"
                : notes
            parts.append("notes: \(capped)")
        }

        let rendered = parts.joined(separator: " — ")
        cachedContextAt = now
        cachedContext = rendered
        return rendered
    }

    /// Invalidate the cache — call this after the user toggles the feature,
    /// grants permission, or changes the calendar selection so the next tick
    /// reflects the new state immediately instead of waiting out the TTL.
    func invalidateCache() {
        cachedContextAt = nil
        cachedContext = nil
    }

    nonisolated static func sanitizeNotesForPrompt(_ notes: String) -> String {
        var sanitized = notes

        if let regex = try? NSRegularExpression(
            pattern: googleTasksEditDisclaimerPattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        sanitized = sanitized
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
