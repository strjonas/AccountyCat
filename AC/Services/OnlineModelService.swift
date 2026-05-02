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
}

enum OnlineModelError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case invalidImageData(String)
    case httpFailure(statusCode: Int, message: String, rawBody: String)
    case emptyResponse
    case malformedResponse

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

actor OnlineModelService: OnlineModelServing {
    nonisolated static let endpointURLString = "https://openrouter.ai/api/v1/chat/completions"
    nonisolated private static let retryableStatusCodes: Set<Int> = [408, 409, 429, 500, 502, 503, 504]

    private let session: URLSession

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

    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput {
        let fallbackModelIdentifiers = Self.requestFallbackModelIdentifiers(
            for: request.modelIdentifier,
            includesImage: request.imagePath != nil
        )
        let maxAttempts = request.source == .chat ? 2 : 1
        var attempt = 0
        var lastError: Error?
        var primaryModelIdentifier = request.modelIdentifier
        var secondaryFallbacks = fallbackModelIdentifiers

        let startTime = Date()

        await ActivityLogService.shared.append(level: .verbose,
            category: "api:\(request.source.rawValue)",
            message: "─── Calling OpenRouter \(request.requestID) ───\n"
                + "model: \(request.modelIdentifier) | source: \(request.source.rawValue)"
                + (fallbackModelIdentifiers.isEmpty ? "" : " | fallbacks: \(fallbackModelIdentifiers.joined(separator: ", "))")
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
                        message: "retry attempt \(attempt)/\(maxAttempts) → \(primaryModelIdentifier) | 650ms backoff"
                    )
                }
                return try await runInference(
                    request,
                    modelIdentifier: primaryModelIdentifier,
                    fallbackModelIdentifiers: secondaryFallbacks,
                    enforceZDR: true,
                    startTime: startTime
                )
            } catch {
                lastError = error
                let onlineError = error as? OnlineModelError
                await OpenRouterHealthStatsService.shared.recordFailure(
                    requestedModel: request.modelIdentifier,
                    source: request.source,
                    statusCode: Self.statusCode(from: onlineError),
                    providerName: Self.providerName(from: onlineError)
                )
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                await ActivityLogService.shared.append(level: .verbose,
                    category: "api:\(request.source.rawValue)",
                    message: "✗ failed → \(primaryModelIdentifier) · \(elapsedMs)ms · \(error.localizedDescription)"
                )
                guard attempt < maxAttempts, Self.isRetryable(error: error) else {
                    throw error
                }
                if request.source == .chat,
                   let promotedModel = secondaryFallbacks.first,
                   promotedModel != primaryModelIdentifier {
                    primaryModelIdentifier = promotedModel
                    secondaryFallbacks.removeAll { $0 == promotedModel }
                }
                try? await Task.sleep(for: .milliseconds(650))
            }
        }

        throw lastError ?? OnlineModelError.malformedResponse
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
            "provider": [
                "zdr": enforceZDR,
            ],
        ]
        if !request.options.thinkingEnabled {
            body["reasoning"] = ["max_reasoning_tokens": 0] as [String: Any]
        }
        if !fallbackModelIdentifiers.isEmpty {
            body["models"] = fallbackModelIdentifiers
        }
        if var provider = body["provider"] as? [String: Any] {
            provider["allow_fallbacks"] = true
            body["provider"] = provider
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("AccountyCat", forHTTPHeaderField: "X-OpenRouter-Title")
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
        if usedModelIdentifier != modelIdentifier {
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

    nonisolated static func requestFallbackModelIdentifiers(
        for modelIdentifier: String,
        includesImage: Bool = false
    ) -> [String] {
        var chain: [String] = []
        if let nonFree = nonFreeModelIdentifier(from: modelIdentifier),
           nonFree != modelIdentifier {
            chain.append(nonFree)
        }
        let tierFallbacks = includesImage
            ? [AITier.economy.byokModelIdentifierImage, AITier.smartest.byokModelIdentifierImage]
            : [AITier.economy.byokModelIdentifierText, AITier.smartest.byokModelIdentifierText]

        for fallback in tierFallbacks where modelIdentifier != fallback && !chain.contains(fallback) {
            chain.append(fallback)
        }
        return chain
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

    nonisolated static func isRetryable(error: Error) -> Bool {
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
}
