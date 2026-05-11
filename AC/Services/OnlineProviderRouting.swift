//
//  OnlineProviderRouting.swift
//  AC
//

import Foundation
import Security

nonisolated struct OnlineProviderRoute: Sendable {
    let provider: OnlineModelProvider
    let modelIdentifier: String
}

enum OnlineProviderRouting {
    nonisolated static let directOpenAIModelIdentifier = "gpt-5.4-nano"

    nonisolated static func route(
        for source: OnlineModelRequestSource,
        requestedModelIdentifier: String
    ) -> OnlineProviderRoute {
        route(
            for: source,
            requestedModelIdentifier: requestedModelIdentifier,
            directOpenAIEnabled: isDirectOpenAIEnabled()
        )
    }

    nonisolated static func route(
        for source: OnlineModelRequestSource,
        requestedModelIdentifier: String,
        directOpenAIEnabled: Bool
    ) -> OnlineProviderRoute {
        if directOpenAIEnabled {
            return OnlineProviderRoute(
                provider: .openAI,
                modelIdentifier: directOpenAIModelIdentifier
            )
        }

        return OnlineProviderRoute(
            provider: .openRouter,
            modelIdentifier: requestedModelIdentifier
        )
    }

    nonisolated static func provider(for source: OnlineModelRequestSource) -> OnlineModelProvider {
        route(
            for: source,
            requestedModelIdentifier: "",
            directOpenAIEnabled: isDirectOpenAIEnabled()
        ).provider
    }

    nonisolated static func effectiveModelIdentifier(
        for source: OnlineModelRequestSource,
        requestedModelIdentifier: String
    ) -> String {
        route(
            for: source,
            requestedModelIdentifier: requestedModelIdentifier,
            directOpenAIEnabled: isDirectOpenAIEnabled()
        ).modelIdentifier
    }

    nonisolated static func apiKey(for provider: OnlineModelProvider) -> String? {
        switch provider {
        case .openAI:
            return OnlineProviderCredentialStore.loadDirectOpenAIAPIKey()
        case .openRouter:
            return OnlineProviderCredentialStore.loadOpenRouterAPIKey()
        }
    }

    nonisolated static func isDirectOpenAIEnabled() -> Bool {
        OnlineProviderRoutingStore.loadDirectOpenAIEnabled()
    }

    nonisolated static func hasActiveAPIKeyConfigured(
        openRouterAPIKey: String,
        directOpenAIAPIKey: String,
        directOpenAIEnabled: Bool
    ) -> Bool {
        let key = directOpenAIEnabled ? directOpenAIAPIKey : openRouterAPIKey
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func activeProvider(
        directOpenAIEnabled: Bool
    ) -> OnlineModelProvider {
        directOpenAIEnabled ? .openAI : .openRouter
    }
}

enum OnlineProviderCredentialStore {
    nonisolated private static let service = "dev.accountycat.credentials"
    nonisolated private static let openRouterAccount = "openrouter_api_key"
    nonisolated private static let directOpenAIAccount = "direct_openai_api_key"
    nonisolated private static let legacyMonitoringOpenAIAccount = "monitoring_openai_api_key"

    nonisolated private static func loadAPIKey(account: String) -> String? {
        guard !ACTestEnvironment.isRunning else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    nonisolated private static func saveAPIKey(_ value: String?, account: String) -> Bool {
        guard !ACTestEnvironment.isRunning else { return false }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return true
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }

        var createQuery = query
        createQuery[kSecValueData] = data
        return SecItemAdd(createQuery as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func loadOpenRouterAPIKey() -> String? {
        loadAPIKey(account: openRouterAccount)
    }

    @discardableResult
    nonisolated static func saveOpenRouterAPIKey(_ value: String?) -> Bool {
        saveAPIKey(value, account: openRouterAccount)
    }

    nonisolated static func loadDirectOpenAIAPIKey() -> String? {
        if let value = loadAPIKey(account: directOpenAIAccount) {
            return value
        }
        return loadAPIKey(account: legacyMonitoringOpenAIAccount)
    }

    @discardableResult
    nonisolated static func saveDirectOpenAIAPIKey(_ value: String?) -> Bool {
        let saved = saveAPIKey(value, account: directOpenAIAccount)
        _ = saveAPIKey(nil, account: legacyMonitoringOpenAIAccount)
        return saved
    }
}

enum OnlineProviderRoutingStore {
    nonisolated private static let directOpenAIKey = "acDirectOpenAIAllTraffic"

    nonisolated static func loadDirectOpenAIEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: directOpenAIKey)
    }

    nonisolated static func saveDirectOpenAIEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: directOpenAIKey)
    }
}
