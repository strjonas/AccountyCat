//
//  AppUpdateService.swift
//  AC
//
//  Best-effort "a newer AC is available" check against the public GitHub
//  releases feed. Intentionally lightweight (no Sparkle): it only *notifies*;
//  the user downloads the DMG from the release page. Fails silent on any
//  error/offline and throttles network checks so it never gets in the way.
//

import Foundation

struct AppUpdateInfo: Equatable, Sendable {
    let latestVersion: String
    let currentVersion: String
    let releaseURL: URL
}

enum AppUpdateService {
    /// `owner/name` of the public release repo (see accountycat-release SKILL).
    static let repository = "strjonas/AccountyCat"
    private static let lastCheckDefaultsKey = "ac.appUpdate.lastCheckAt"
    private static let minCheckInterval: TimeInterval = 6 * 60 * 60  // 6h

    static var currentBundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns update info when a strictly-newer release exists, else nil. Never
    /// throws: offline, throttled, non-200, or a malformed payload all yield nil.
    static func checkForUpdate(
        currentVersion: String = currentBundleVersion,
        force: Bool = false,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) async -> AppUpdateInfo? {
        if !force, let last = defaults.object(forKey: lastCheckDefaultsKey) as? Date,
           now.timeIntervalSince(last) < minCheckInterval {
            return nil
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            defaults.set(now, forKey: lastCheckDefaultsKey)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else { return nil }

            let latest = normalizedVersion(tag)
            guard isVersion(latest, newerThan: normalizedVersion(currentVersion)) else { return nil }

            let urlString = (json["html_url"] as? String)
                ?? "https://github.com/\(repository)/releases/latest"
            guard let releaseURL = URL(string: urlString) else { return nil }
            return AppUpdateInfo(
                latestVersion: latest,
                currentVersion: normalizedVersion(currentVersion),
                releaseURL: releaseURL
            )
        } catch {
            return nil
        }
    }

    /// Strips a leading `v` and surrounding whitespace ("v1.05" → "1.05").
    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    /// Numeric, component-wise version comparison ("1.10" > "1.9" > "1.0.5" > "1.0").
    /// Non-numeric components degrade to 0 so a malformed tag never spuriously wins.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
