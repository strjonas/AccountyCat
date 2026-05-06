//
//  OnlineModelService.swift
//  AC
//

import Foundation
import Security

enum OnlineModelRequestSource: String, Sendable {
    case chat
    case policyMemory = "policy-memory"
    case memoryConsolidation = "memory-consolidation"
    case monitoringText = "monitoring-text"
    case monitoringVision = "monitoring-vision"
    case safelistAppeal = "safelist-appeal"
}

struct OnlineModelRequest: Sendable {
    var source: OnlineModelRequestSource
    var requestID: String
    var modelIdentifier: String
    var systemPrompt: String
    var userPrompt: String
    var imagePath: String?
    var options: RuntimeInferenceOptions

    init(
        source: OnlineModelRequestSource,
        requestID: String = UUID().uuidString,
        modelIdentifier: String,
        systemPrompt: String,
        userPrompt: String,
        imagePath: String?,
        options: RuntimeInferenceOptions
    ) {
        self.source = source
        self.requestID = requestID
        self.modelIdentifier = modelIdentifier
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.imagePath = imagePath
        self.options = options
    }
}

protocol OnlineModelServing: Sendable {
    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput
    func runFirstSuccessfulInference(from requests: [OnlineModelRequest]) async throws -> RuntimeProcessOutput
    func hasHadSuccessfulChat() async -> Bool
}

enum OnlineModelError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint
    case invalidImageData(String)
    case httpFailure(statusCode: Int, message: String, rawBody: String)
    case emptyResponse
    case malformedResponse
    case allRequestsFailed([String])

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API key is missing."
        case .invalidEndpoint:
            return "The OpenRouter endpoint is invalid."
        case let .invalidImageData(path):
            return "Couldn't encode screenshot for upload: \(path)"
        case let .httpFailure(statusCode, message, rawBody):
            return "OpenRouter request failed (\(statusCode)): \(message) | raw body: \(rawBody)"
        case .emptyResponse:
            return "OpenRouter returned no message content."
        case .malformedResponse:
            return "OpenRouter returned an unexpected response."
        case let .allRequestsFailed(messages):
            let detail = messages.suffix(3).joined(separator: " | ")
            return detail.isEmpty
                ? "All OpenRouter backup requests failed."
                : "All OpenRouter backup requests failed: \(detail)"
        }
    }
}

enum OnlineModelCredentialStore {
    nonisolated private static let service = "dev.accountycat.credentials"
    nonisolated private static let account = "openrouter_api_key"

    nonisolated static func loadAPIKey() -> String? {
        guard NSClassFromString("XCTest") == nil else { return nil }
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
    nonisolated static func saveAPIKey(_ value: String?) -> Bool {
        guard NSClassFromString("XCTest") == nil else { return false }
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
}

struct OpenRouterKeyInfo: Codable {
    struct Data: Codable {
        let label: String
        let usage: Double
        let usageDaily: Double
        let usageMonthly: Double
        let limit: Double?
        let limitRemaining: Double?
        let isFreeTier: Bool

        enum CodingKeys: String, CodingKey {
            case label, usage, limit
            case usageDaily = "usage_daily"
            case usageMonthly = "usage_monthly"
            case limitRemaining = "limit_remaining"
            case isFreeTier = "is_free_tier"
        }

        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            usage = try c.decode(Double.self, forKey: .usage)
            usageDaily = try c.decode(Double.self, forKey: .usageDaily)
            usageMonthly = try c.decode(Double.self, forKey: .usageMonthly)
            limit = try c.decodeIfPresent(Double.self, forKey: .limit)
            limitRemaining = try c.decodeIfPresent(Double.self, forKey: .limitRemaining)
            isFreeTier = try c.decode(Bool.self, forKey: .isFreeTier)
        }
    }
    let data: Data

    enum CodingKeys: String, CodingKey {
        case data
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(Data.self, forKey: .data)
    }
}



actor OnlineModelService: OnlineModelServing {
    nonisolated static let endpointURLString = "https://openrouter.ai/api/v1/chat/completions"
    nonisolated static let premiumFallbackModelIdentifier = "google/gemini-3-flash-preview"
    nonisolated private static let retryableStatusCodes: Set<Int> = [408, 409, 429, 500, 502, 503, 504]
    nonisolated private static let premiumMaxSuccessCount = 5

    private let session: URLSession
    private var premiumSuccessCount: Int = 0
    private var hasSuccessfulChat: Bool = false

    private enum ParallelInferenceResult: Sendable {
        case success(RuntimeProcessOutput)
        case failure(String)
    }

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Premium Path

    private func isPremiumPath(for source: OnlineModelRequestSource) -> Bool {
        guard source == .monitoringText || source == .monitoringVision || source == .chat || source == .policyMemory else {
            return false
        }
        return premiumSuccessCount < Self.premiumMaxSuccessCount
    }

    private func recordSuccessIfNeeded(for source: OnlineModelRequestSource) {
        if source == .monitoringText || source == .monitoringVision || source == .chat || source == .policyMemory {
            premiumSuccessCount = min(premiumSuccessCount + 1, Self.premiumMaxSuccessCount)
        }
        if source == .chat {
            hasSuccessfulChat = true
        }
    }

    func hasHadSuccessfulChat() async -> Bool {
        hasSuccessfulChat
    }

    // MARK: - Inference

    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput {
        let isPremium = isPremiumPath(for: request.source)
        let fallbackModelIdentifiers = await Self.requestFallbackModelIdentifiers(
            for: request.modelIdentifier,
            includesImage: request.imagePath != nil,
            isPremium: isPremium
        )
        let maxAttempts = Self.maxAttempts(for: request.source, isPremium: isPremium)
        var attempt = 0
        var lastError: Error?
        var primaryModelIdentifier = request.modelIdentifier
        var secondaryFallbacks = fallbackModelIdentifiers
        if await OpenRouterHealthStatsService.shared.isModelBanned(primaryModelIdentifier),
           let promotedModel = secondaryFallbacks.first {
            primaryModelIdentifier = promotedModel
            secondaryFallbacks.removeAll { $0 == promotedModel }
        }

        let startTime = Date()

        await ActivityLogService.shared.append(level: .verbose,
            category: "api:\(request.source.rawValue)",
            message: "─── Calling OpenRouter \(request.requestID) ───\n"
                + "model: \(request.modelIdentifier) | source: \(request.source.rawValue)"
                + (fallbackModelIdentifiers.isEmpty ? "" : " | fallbacks: \(fallbackModelIdentifiers.joined(separator: ", "))")
                + (isPremium ? " | premium-path" : "")
        )

        while attempt < maxAttempts {
            attempt += 1
            do {
                if attempt > 1 {
                    let retryDetail = primaryModelIdentifier == request.modelIdentifier
                        ? "after transient failure"
                        : "using backup model \(primaryModelIdentifier)"
                    await OpenRouterHealthStatsService.shared.recordRetry(requestedModel: request.modelIdentifier)
                    await ActivityLogService.shared.append(
                        category: "openrouter-retry",
                        message: "[\(request.source.rawValue) \(request.requestID)] Retrying OpenRouter request \(retryDetail) (attempt \(attempt)/\(maxAttempts))."
                    )
                    await ActivityLogService.shared.append(level: .verbose,
                        category: "api:\(request.source.rawValue)",
                        message: "retry attempt \(attempt)/\(maxAttempts) → \(primaryModelIdentifier) | \(Self.backoffMilliseconds(for: attempt))ms backoff"
                    )
                }
                let result = try await runInference(
                    request,
                    modelIdentifier: primaryModelIdentifier,
                    fallbackModelIdentifiers: secondaryFallbacks,
                    enforceZDR: true,
                    startTime: startTime
                )
                recordSuccessIfNeeded(for: request.source)
                return result
            } catch {
                lastError = error
                if Self.isCancellation(error) {
                    let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    await ActivityLogService.shared.append(level: .verbose,
                        category: "api:\(request.source.rawValue)",
                        message: "cancelled → \(primaryModelIdentifier) · \(elapsedMs)ms"
                    )
                    throw error
                }
                let onlineError = error as? OnlineModelError
                let retryAfter = Self.retryAfterSeconds(from: onlineError)
                if Self.shouldRecordHealthFailure(error) {
                    await OpenRouterHealthStatsService.shared.recordFailure(
                        requestedModel: request.modelIdentifier,
                        source: request.source,
                        statusCode: Self.statusCode(from: onlineError),
                        providerName: Self.providerName(from: onlineError),
                        countsTowardBan: Self.countsTowardModelBan(error)
                    )
                }
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                await ActivityLogService.shared.append(level: .verbose,
                    category: "api:\(request.source.rawValue)",
                    message: "✗ failed → \(primaryModelIdentifier) · \(elapsedMs)ms · \(error.localizedDescription)"
                )
                guard attempt < maxAttempts, Self.isRetryable(error: error) else {
                    throw error
                }
                if let promotedModel = secondaryFallbacks.first,
                   promotedModel != primaryModelIdentifier {
                    primaryModelIdentifier = promotedModel
                    secondaryFallbacks.removeAll { $0 == promotedModel }
                }
                let backoffMs = retryAfter.map { UInt64($0 * 1000) } ?? Self.backoffMilliseconds(for: attempt)
                try? await Task.sleep(for: .milliseconds(backoffMs))
            }
        }

        throw lastError ?? OnlineModelError.malformedResponse
    }

    /// Fire multiple requests in parallel and return the first successful result.
    /// Failed children are collected; a fast failure must not mask a slower success.
    /// Cancelled losers are ignored by model health recording inside `runInference`.
    func runFirstSuccessfulInference(from requests: [OnlineModelRequest]) async throws -> RuntimeProcessOutput {
        guard !requests.isEmpty else {
            throw OnlineModelError.malformedResponse
        }
        return try await withThrowingTaskGroup(of: ParallelInferenceResult.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        return .success(try await self.runInference(request))
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            }
            var failures: [String] = []
            for try await result in group {
                switch result {
                case let .success(output):
                    group.cancelAll()
                    return output
                case let .failure(message):
                    failures.append(message)
                }
            }
            throw OnlineModelError.allRequestsFailed(failures)
        }
    }
    private func runInference(
        _ request: OnlineModelRequest,
        modelIdentifier: String,
        fallbackModelIdentifiers: [String],
        enforceZDR: Bool,
        startTime: Date = Date()
    ) async throws -> RuntimeProcessOutput {
        let apiKey = (OnlineModelCredentialStore.loadAPIKey() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw OnlineModelError.missingAPIKey
        }
        guard let endpointURL = URL(string: Self.endpointURLString) else {
            throw OnlineModelError.invalidEndpoint
        }

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": request.userPrompt,
            ]
        ]
        if let imagePath = request.imagePath {
            userContent.append(
                [
                    "type": "image_url",
                    "image_url": [
                        "url": try Self.dataURL(forImageAtPath: imagePath),
                    ],
                ]
            )
        }

        var body: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                [
                    "role": "system",
                    "content": request.systemPrompt,
                ],
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
            "max_tokens": request.options.maxTokens,
            "temperature": request.options.temperature,
            "top_p": request.options.topP,
            "top_k": request.options.topK,
            "stream": false,
            "response_format": [
                "type": "json_object",
            ],
            "provider": Self.providerPreferences(
                enforceZDR: enforceZDR,
                includesModelFallbacks: !fallbackModelIdentifiers.isEmpty,
                source: request.source
            ),
        ]
        if !request.options.thinkingEnabled {
            body["reasoning"] = ["max_reasoning_tokens": 0] as [String: Any]
        }
        if !fallbackModelIdentifiers.isEmpty {
            body["models"] = fallbackModelIdentifiers
        }

        let isPremium = isPremiumPath(for: request.source)
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("AccountyCat", forHTTPHeaderField: "X-OpenRouter-Title")
        urlRequest.timeoutInterval = Self.timeoutInterval(for: request.source, options: request.options, isPremium: isPremium)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OnlineModelError.malformedResponse
        }

        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = Self.errorMessage(from: json) ?? String(decoding: data, as: UTF8.self)
            throw OnlineModelError.httpFailure(
                statusCode: httpResponse.statusCode,
                message: errorMessage.cleanedSingleLine,
                rawBody: String(decoding: data, as: UTF8.self).cleanedSingleLine
            )
        }

        guard let json else {
            throw OnlineModelError.malformedResponse
        }

        guard let content = Self.messageContent(from: json),
              !content.cleanedSingleLine.isEmpty else {
            throw OnlineModelError.emptyResponse
        }

        let usedModelIdentifier = Self.responseModelIdentifier(from: json) ?? modelIdentifier
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let usage = Self.tokenUsage(from: json)
        let providerName = (json["provider"] as? String) ?? (json["route"] as? [String: Any])?["provider"] as? String
        let tokenSummary = usage.map { "\($0.promptTokens)p/\($0.completionTokens)c" } ?? "— tok"
        let costStr = usage?.costUSD.map { String(format: "$%.5f", $0) }

        await OpenRouterHealthStatsService.shared.recordSuccess(
            requestedModel: request.modelIdentifier,
            servedModel: usedModelIdentifier,
            source: request.source
        )
        if !Self.modelIdentifiersEquivalent(usedModelIdentifier, modelIdentifier) {
            await ActivityLogService.shared.append(
                category: "openrouter-fallback",
                message: "[\(request.source.rawValue) \(request.requestID)] OpenRouter served \(usedModelIdentifier) instead of \(modelIdentifier) after provider/model fallback (ZDR enforced)."
            )
        }

        await ActivityLogService.shared.append(level: .verbose,
            category: "api:\(request.source.rawValue)",
            message: "✓ \(httpResponse.statusCode) → \(usedModelIdentifier) · \(elapsedMs)ms · \(tokenSummary)"
                + (providerName.map { " · provider: \($0)" } ?? "")
                + (costStr.map { " · cost: \($0)" } ?? "")
        )

        return RuntimeProcessOutput(
            stdout: content,
            stderr: Self.usageSummary(from: json),
            usedModelIdentifier: usedModelIdentifier,
            tokenUsage: usage
        )
    }

    // MARK: - Helpers

    nonisolated private static func tokenUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let prompt = usage["prompt_tokens"] as? Int ?? 0
        let completion = usage["completion_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int
        let cost = usage["cost"] as? Double
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        let image = (usage["prompt_tokens_details"] as? [String: Any])?["image_tokens"] as? Int
        guard prompt > 0 || completion > 0 else { return nil }
        return TokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            cacheReadTokens: cached,
            imageTokens: image,
            costUSD: cost,
            estimated: false
        )
    }

    static func requestFallbackModelIdentifiers(
        for modelIdentifier: String,
        includesImage: Bool = false,
        isPremium: Bool = false,
        healthStats: OpenRouterHealthStatsService = .shared
    ) async -> [String] {
        var chain: [String] = []

        // 1) Non-free variant of primary
        if let nonFree = nonFreeModelIdentifier(from: modelIdentifier),
           nonFree != modelIdentifier {
            chain.append(nonFree)
        }

        // 2) Tier fallbacks
        // Text requests interleave the balanced image model as first fallback:
        // it handles text well and avoids degrading to economy-quality text alone.
        let tierFallbacks = includesImage
            ? [AITier.economy.byokModelIdentifierImage, AITier.smartest.byokModelIdentifierImage]
            : [
                AITier.balanced.byokModelIdentifierImage,
                AITier.economy.byokModelIdentifierText,
                AITier.smartest.byokModelIdentifierText,
            ]
        for fallback in tierFallbacks where modelIdentifier != fallback && !chain.contains(fallback) {
            chain.append(fallback)
        }

        // 3) Premium fallback. Intermediate image-quality models absorb routine
        // instability before the last-resort Gemini rescue — the user expects a
        // comparable experience even when the primary model is unavailable.
        if isPremium {
            let premiumExtras: [String] = [
                AITier.balanced.byokModelIdentifierImage,
                AITier.smartest.byokModelIdentifierImage,
                Self.premiumFallbackModelIdentifier,
            ]
            for fallback in premiumExtras
            where modelIdentifier != fallback && !chain.contains(fallback) {
                chain.append(fallback)
            }
        }

        // 4) Health-aware filtering: deprioritize banned or high-failure models
        let healthy = await healthStats.sortedHealthyModels(chain)
        return healthy
    }

    nonisolated static func providerPreferences(
        enforceZDR: Bool,
        includesModelFallbacks: Bool,
        source: OnlineModelRequestSource
    ) -> [String: Any] {
        var provider: [String: Any] = [
            "zdr": enforceZDR,
            "allow_fallbacks": true,
            "require_parameters": true,
            "sort": "latency",
            "preferred_max_latency": preferredMaxLatency(for: source),
        ]

        // For background maintenance, use the fastest healthy endpoint across the
        // fallback chain. User-facing monitoring/chat keep primary-model grouping
        // so a fast but weaker fallback is used only after the primary model fails.
        if includesModelFallbacks,
           source == .policyMemory || source == .memoryConsolidation || source == .safelistAppeal {
            provider["sort"] = [
                "by": "latency",
                "partition": "none",
            ] as [String: Any]
        }

        return provider
    }

    nonisolated static func modelIdentifiersEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedComparableModelIdentifier(lhs)
        let right = normalizedComparableModelIdentifier(rhs)
        return left == right
    }

    nonisolated private static func normalizedComparableModelIdentifier(_ identifier: String) -> String {
        let trimmed = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFree = trimmed.hasSuffix(":free") ? String(trimmed.dropLast(5)) : trimmed
        let parts = withoutFree.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return withoutFree }

        let provider = parts[0]
        var model = parts[1]
        if let match = model.range(
            of: #"-20\d{6}$"#,
            options: .regularExpression
        ) {
            model.removeSubrange(match)
        }
        return "\(provider)/\(model)"
    }

    nonisolated private static func maxAttempts(for source: OnlineModelRequestSource, isPremium: Bool) -> Int {
        switch source {
        case .chat, .monitoringText, .monitoringVision:
            return isPremium ? 4 : 3
        case .policyMemory, .memoryConsolidation, .safelistAppeal:
            return 2
        }
    }

    nonisolated private static func backoffMilliseconds(for attempt: Int) -> UInt64 {
        switch attempt {
        case 1: return 500
        case 2: return 1500
        case 3: return 4000
        default: return 4000
        }
    }

    nonisolated private static func timeoutInterval(
        for source: OnlineModelRequestSource,
        options: RuntimeInferenceOptions,
        isPremium: Bool
    ) -> TimeInterval {
        let sourceCeiling: TimeInterval
        switch source {
        case .monitoringText, .monitoringVision:
            sourceCeiling = isPremium ? 20 : 14
        case .chat:
            sourceCeiling = isPremium ? 25 : 18
        case .policyMemory, .memoryConsolidation, .safelistAppeal:
            sourceCeiling = 14
        }
        return min(TimeInterval(options.timeoutSeconds), sourceCeiling)
    }

    nonisolated private static func preferredMaxLatency(
        for source: OnlineModelRequestSource
    ) -> [String: Double] {
        switch source {
        case .monitoringText, .monitoringVision:
            return ["p50": 2.0, "p90": 6.0]
        case .chat:
            return ["p50": 2.0, "p90": 7.0]
        case .policyMemory, .memoryConsolidation, .safelistAppeal:
            return ["p50": 2.0, "p90": 8.0]
        }
    }

    nonisolated private static func nonFreeModelIdentifier(from modelIdentifier: String) -> String? {
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed == "google/gemma-4-31b-it:free" {
            return AITier.balanced.byokModelIdentifierImage
        }

        guard trimmed.hasSuffix(":free") else {
            return nil
        }

        return String(trimmed.dropLast(5))
    }

    nonisolated private static func errorMessage(from json: [String: Any]?) -> String? {
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated private static func shouldRecordHealthFailure(_ error: Error) -> Bool {
        guard !isCancellation(error) else {
            return false
        }
        if let onlineError = error as? OnlineModelError {
            switch onlineError {
            case let .httpFailure(statusCode, _, _):
                return retryableStatusCodes.contains(statusCode)
            case .emptyResponse, .malformedResponse:
                return true
            case .missingAPIKey, .invalidEndpoint, .invalidImageData, .allRequestsFailed:
                return false
            }
        }
        return false
    }

    nonisolated private static func countsTowardModelBan(_ error: Error) -> Bool {
        guard !isCancellation(error) else {
            return false
        }
        if let onlineError = error as? OnlineModelError {
            switch onlineError {
            case let .httpFailure(statusCode, _, _):
                return retryableStatusCodes.contains(statusCode)
            case .emptyResponse, .malformedResponse:
                return true
            case .missingAPIKey, .invalidEndpoint, .invalidImageData, .allRequestsFailed:
                return false
            }
        }
        return false
    }

    nonisolated static func isRetryable(error: Error) -> Bool {
        if isCancellation(error) {
            return false
        }
        if let onlineError = error as? OnlineModelError {
            switch onlineError {
            case let .httpFailure(statusCode, _, _):
                return retryableStatusCodes.contains(statusCode)
            case .malformedResponse, .emptyResponse:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
        ].contains(nsError.code)
    }

    /// Extracts a server-suggested retry delay from the raw error body if present.
    nonisolated private static func retryAfterSeconds(from error: OnlineModelError?) -> TimeInterval? {
        guard case let .httpFailure(statusCode, _, rawBody) = error,
              retryableStatusCodes.contains(statusCode) else { return nil }
        guard let data = rawBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let metadata = errorObj["metadata"] as? [String: Any],
              let retryAfter = metadata["retry_after"] as? TimeInterval ?? metadata["retry_after"] as? Double else {
            return nil
        }
        return retryAfter > 0 ? retryAfter : nil
    }

    nonisolated static func responseModelIdentifier(from json: [String: Any]) -> String? {
        if let model = json["model"] as? String,
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        return nil
    }

    nonisolated private static func statusCode(from error: OnlineModelError?) -> Int? {
        guard case let .httpFailure(statusCode, _, _) = error else { return nil }
        return statusCode
    }

    nonisolated private static func providerName(from error: OnlineModelError?) -> String? {
        guard case let .httpFailure(_, _, rawBody) = error,
              let data = rawBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let metadata = error["metadata"] as? [String: Any],
              let providerName = metadata["provider_name"] as? String else {
            return nil
        }
        return providerName
    }

    nonisolated private static func messageContent(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return nil
        }

        if let content = message["content"] as? String {
            return content
        }

        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let value = part["text"] as? String { return value }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }

        return nil
    }

    nonisolated private static func usageSummary(from json: [String: Any]) -> String {
        guard let usage = json["usage"] as? [String: Any] else {
            return ""
        }

        let promptTokens = usage["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage["completion_tokens"] as? Int ?? 0
        let totalTokens = usage["total_tokens"] as? Int ?? (promptTokens + completionTokens)
        let cost = usage["cost"] as? Double

        if let cost {
            return "usage prompt_tokens=\(promptTokens) completion_tokens=\(completionTokens) total_tokens=\(totalTokens) cost=\(cost)"
        }
        return "usage prompt_tokens=\(promptTokens) completion_tokens=\(completionTokens) total_tokens=\(totalTokens)"
    }

    nonisolated private static func dataURL(forImageAtPath path: String) throws -> String {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            throw OnlineModelError.invalidImageData(path)
        }
        let mimeType = mimeType(for: fileURL)
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    nonisolated private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/png"
        }
    }

    func fetchKeyInfo(apiKey: String) async throws -> OpenRouterKeyInfo {
        guard let url = URL(string: "https://openrouter.ai/api/v1/key") else {
            throw OnlineModelError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("AccountyCat", forHTTPHeaderField: "X-OpenRouter-Title")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OnlineModelError.malformedResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OnlineModelError.httpFailure(
                statusCode: httpResponse.statusCode,
                message: "Failed to fetch key info",
                rawBody: body
            )
        }
        return try JSONDecoder().decode(OpenRouterKeyInfo.self, from: data)
    }
}
