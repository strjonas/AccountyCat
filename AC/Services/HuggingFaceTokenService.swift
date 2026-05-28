//
//  HuggingFaceTokenService.swift
//  AC
//
//  Fetches a read-only Hugging Face access token from accountycat.com so llama.cpp model
//  downloads run authenticated. Unauthenticated HF downloads are throttled well below the
//  connection's real ceiling (measured ~1.4 MB/s single-stream vs the pipe's true rate),
//  which is the dominant first-run wait for users on fast connections. HF's own response
//  header asks for a token "to enable higher rate limits and faster downloads."
//
//  The token never ships in the app binary — it lives in a server env var and is fetched at
//  install time. The token is read-only and scoped to public repos, so a leak exposes nothing
//  private; worst case the server rotates it.
//
//  Every failure path returns nil and the caller downloads unauthenticated (the prior
//  behavior), so a server outage or missing key never blocks setup.
//

import Foundation

enum HuggingFaceTokenService {
    /// Production token endpoint. Override with AC_HF_TOKEN_ENDPOINT for local testing.
    static var endpoint: URL {
        if let override = ProcessInfo.processInfo.environment["AC_HF_TOKEN_ENDPOINT"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://accountycat.com/api/hf-token")!
    }

    private actor Cache {
        private var token: String?
        private var fetchedAt: Date?

        func value(maxAge: TimeInterval) -> String? {
            guard let token, let fetchedAt,
                Date().timeIntervalSince(fetchedAt) < maxAge
            else { return nil }
            return token
        }

        func store(_ token: String) {
            self.token = token
            self.fetchedAt = Date()
        }
    }

    private static let cache = Cache()

    /// Returns a HF token if the server provides one, otherwise nil. Never throws — any
    /// network/parse failure falls back to unauthenticated download.
    static func fetchToken() async -> String? {
        if let cached = await cache.value(maxAge: 3600) { return cached }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(PromoRedemptionService.installId, forHTTPHeaderField: "X-AC-Install")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let token = obj["token"] as? String,
            !token.isEmpty
        else {
            return nil
        }

        await cache.store(token)
        return token
    }
}
