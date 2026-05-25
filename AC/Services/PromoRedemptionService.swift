//
//  PromoRedemptionService.swift
//  AC
//
//  Redeems a limited free-trial ("promo") code against accountycat.com, which mints a
//  small capped OpenRouter key and returns it. Used by the onboarding wizard so a tester
//  can go: download → paste code → permissions → start, with no account setup.
//
//  Transparency: redeeming contacts accountycat.com only to configure trial access. After
//  redemption the returned key is used to talk to OpenRouter directly — nothing about the
//  user's monitored activity is ever sent to our server.
//

import Foundation

struct PromoRedemptionResult {
    let apiKey: String
    let limitUSD: Double
}

enum PromoRedemptionError: Error {
    case invalidCode
    case exhausted
    case alreadyRedeemed
    case rateLimited
    case unavailable
    case network(String)

    /// Short, friendly, non-shaming message suitable for the onboarding UI.
    var userMessage: String {
        switch self {
        case .invalidCode:
            return "That code isn't valid. Double-check it, or grab one at accountycat.com/trial."
        case .exhausted:
            return "All free trial slots for this code are taken. Email fb@accountycat.com — there may be more."
        case .alreadyRedeemed:
            return "This Mac already used a trial code. You're set — continue, or add your own key in Settings → AI."
        case .rateLimited:
            return "Too many tries from here. Give it a minute and try again."
        case .unavailable:
            return "Trials are temporarily unavailable. Try again later, or skip this and set AC up yourself."
        case .network(let detail):
            return "Couldn't reach the trial server (\(detail)). Check your connection and try again."
        }
    }
}

enum PromoRedemptionService {
    /// Production redeem endpoint. Override with the AC_REDEEM_ENDPOINT env var for local testing.
    static var endpoint: URL {
        if let override = ProcessInfo.processInfo.environment["AC_REDEEM_ENDPOINT"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://accountycat.com/api/redeem")!
    }

    /// Stable per-install identifier so re-running onboarding doesn't burn a new trial slot.
    static var installId: String {
        let key = "acInstallId"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.count >= 8 {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    static func redeem(code: String) async -> Result<PromoRedemptionResult, PromoRedemptionError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidCode) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let payload: [String: String] = ["code": trimmed, "installId": installId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            if (obj["ok"] as? Bool) == true, let key = obj["apiKey"] as? String, !key.isEmpty {
                let limit =
                    (obj["limitUSD"] as? Double) ?? (obj["limitUSD"] as? NSNumber)?.doubleValue ?? 0
                return .success(
                    PromoRedemptionResult(
                        apiKey: key,
                        limitUSD: limit
                    ))
            }

            switch obj["reason"] as? String {
            case "invalid_code": return .failure(.invalidCode)
            case "exhausted": return .failure(.exhausted)
            case "already_redeemed": return .failure(.alreadyRedeemed)
            case "rate_limited": return .failure(.rateLimited)
            case "unavailable": return .failure(.unavailable)
            default: return .failure(.network("unexpected response"))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
