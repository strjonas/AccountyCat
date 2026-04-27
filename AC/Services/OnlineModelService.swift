//
//  OnlineModelService.swift
//  AC
//

import Foundation
import Security

struct OnlineModelRequest: Sendable {
    var modelIdentifier: String
    var systemPrompt: String
    var userPrompt: String
    var imagePath: String?
    var options: RuntimeInferenceOptions
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
    nonisolated static let fallbackNonFreeModelIdentifier = "google/gemma-4-31b-it"
    nonisolated static let zdrFallbackModelIdentifier = "mistralai/mistral-small-3.1-24b-instruct"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    func runInference(_ request: OnlineModelRequest) async throws -> RuntimeProcessOutput {
        // Try the requested model first.
        var lastError: OnlineModelError
        do {
            return try await runInference(
                request,
                modelIdentifier: request.modelIdentifier,
                enforceZDR: true
            )
        } catch let error as OnlineModelError {
            lastError = error
        }

        // Build a prioritised fallback chain from the first failure.
        let chain = Self.fallbackChain(for: request.modelIdentifier, error: lastError)
        guard !chain.isEmpty else { throw lastError }

        for fallbackID in chain {
            await ActivityLogService.shared.append(
                category: "chat-fallback",
                message: "OpenRouter couldn't serve \(request.modelIdentifier); retrying with \(fallbackID) (ZDR enforced)."
            )
            do {
                return try await runInference(
                    request,
                    modelIdentifier: fallbackID,
                    enforceZDR: true
                )
            } catch let error as OnlineModelError {
                lastError = error
                // Only keep walking the chain for ZDR unavailability — any other
                // error (rate-limit on fallback, auth, etc.) should surface immediately.
                guard Self.isZDRUnavailableFallbackWarranted(error: error) else {
                    throw error
                }
            }
        }

        throw lastError
    }

    private func runInference(
        _ request: OnlineModelRequest,
        modelIdentifier: String,
        enforceZDR: Bool
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

        let body: [String: Any] = [
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
                "sort": "latency",
                "zdr": enforceZDR,
            ],
        ]

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

        return RuntimeProcessOutput(
            stdout: content,
            stderr: Self.usageSummary(from: json)
        )
    }

    /// Returns an ordered list of model identifiers to try after `modelIdentifier`
    /// fails with `error`.  The caller walks this chain in order, stopping as
    /// soon as one succeeds (or a non-retryable error is thrown).
    nonisolated private static func fallbackChain(
        for modelIdentifier: String,
        error: OnlineModelError
    ) -> [String] {
        if isRateLimitFallbackWarranted(error: error) {
            // Rate-limited: try the paid variant of the same model only.
            if let nonFree = nonFreeModelIdentifier(from: modelIdentifier),
               nonFree != modelIdentifier {
                return [nonFree]
            }
            return []
        }

        if isZDRUnavailableFallbackWarranted(error: error) {
            var chain: [String] = []
            // 1. Try paid variant of same model first — different provider pool,
            //    higher chance of finding a ZDR-capable endpoint.
            if let nonFree = nonFreeModelIdentifier(from: modelIdentifier),
               nonFree != modelIdentifier {
                chain.append(nonFree)
            }
            // 2. Fall back to the designated ZDR fallback model (different family).
            if modelIdentifier != zdrFallbackModelIdentifier,
               !chain.contains(zdrFallbackModelIdentifier) {
                chain.append(zdrFallbackModelIdentifier)
            }
            return chain
        }

        return []
    }

    nonisolated private static func nonFreeModelIdentifier(from modelIdentifier: String) -> String? {
        let trimmed = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed == "google/gemma-4-31b-it:free" {
            return fallbackNonFreeModelIdentifier
        }

        guard trimmed.hasSuffix(":free") else {
            return nil
        }

        return String(trimmed.dropLast(5))
    }

    nonisolated private static func isZDRUnavailableFallbackWarranted(error: OnlineModelError) -> Bool {
        guard case let .httpFailure(statusCode, message, rawBody) = error,
              statusCode == 404 else {
            return false
        }
        let combined = [message, rawBody].joined(separator: " ").lowercased()
        return combined.contains("data policy") || combined.contains("zero data retention")
    }

    nonisolated private static func isRateLimitFallbackWarranted(error: OnlineModelError) -> Bool {
        guard case let .httpFailure(statusCode, message, rawBody) = error,
              statusCode == 429 else {
            return false
        }

        let combined = [message, rawBody].joined(separator: " ").lowercased()
        return combined.contains("rate-limited") || combined.contains("rate limited")
    }

    nonisolated private static func errorMessage(from json: [String: Any]?) -> String? {
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
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
