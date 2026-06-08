//
//  PromptBudgetGuard.swift
//  AC
//

import Foundation
import ImageIO

struct PromptBudgetGuardRequest: Sendable {
    var serverPort: Int
    var content: String
    var timeoutSeconds: TimeInterval
}

struct PromptBudgetGuardChatRequest: Sendable {
    var serverPort: Int
    var systemPrompt: String
    var userPrompt: String
    var thinkingEnabled: Bool
    var timeoutSeconds: TimeInterval
}

struct PromptBudgetGuardResult: Sendable, Equatable {
    var userPrompt: String
    var wasTruncated: Bool
    var warning: String?
    var promptTokensEstimate: Int
    var imageTokensEstimate: Int
}

enum PromptBudgetGuard {
    typealias TokenizeTransport = @Sendable (PromptBudgetGuardRequest) async throws -> Int
    typealias ChatTokenizeTransport = @Sendable (PromptBudgetGuardChatRequest) async throws -> Int

    private static let heuristicTokenThresholdRatio = 0.7
    nonisolated private static let imageMaxDimensionLadder = [1600, 1280, 1024, 768, 512]

    struct PreflightPlan: Sendable, Equatable {
        var recommendedCtxSize: Int
        var imageMaxDimension: Int?
        var estimatedPromptTokens: Int
        var estimatedImageTokens: Int
        var exceededGrowthCap: Bool
    }

    nonisolated static func preflightPlan(
        systemPrompt: String,
        userPrompt: String,
        imagePath: String?,
        ctxSize: Int,
        maxTokens: Int,
        maxCtxGrowth: Int
    ) -> PreflightPlan {
        let reserve = max(maxTokens, ctxSize / 10)
        let promptTokens = estimatedTextTokens(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let imageSizing = recommendedImageSizing(
            imagePath: imagePath,
            promptTokens: promptTokens,
            ctxSize: ctxSize,
            maxTokens: maxTokens,
            reserve: reserve,
            maxCtxGrowth: maxCtxGrowth
        )
        let fullRequiredCtx = promptTokens + imageSizing.estimatedImageTokens + reserve + maxTokens
        let recommendedCtx = min(max(ctxSize, fullRequiredCtx), ctxSize + maxCtxGrowth)

        return PreflightPlan(
            recommendedCtxSize: recommendedCtx,
            imageMaxDimension: imageSizing.imageMaxDimension,
            estimatedPromptTokens: promptTokens,
            estimatedImageTokens: imageSizing.estimatedImageTokens,
            exceededGrowthCap: fullRequiredCtx > ctxSize + maxCtxGrowth
        )
    }

    static func guardedUserPrompt(
        systemPrompt: String,
        userPrompt: String,
        imagePath: String?,
        ctxSize: Int,
        maxTokens: Int,
        serverPort: Int,
        thinkingEnabled: Bool = false,
        transport: TokenizeTransport,
        chatTransport: ChatTokenizeTransport? = nil
    ) async -> PromptBudgetGuardResult {
        let imageTokens = imagePath.map(estimatedImageTokens(for:)) ?? 0
        let heuristicPromptTokens = estimatedTextTokens(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let heuristicTotal = heuristicPromptTokens + imageTokens
        let requiresExactTokenization =
            chatTransport != nil
            || Double(heuristicTotal) > Double(ctxSize) * heuristicTokenThresholdRatio

        let reserve = max(maxTokens, ctxSize / 10)
        let allowedPromptTokens = max(0, ctxSize - reserve - maxTokens)

        var exactChatPromptTokens: Int?
        let exactSystemTokens: Int?
        let exactUserTokens: Int?
        let warning: String?

        if requiresExactTokenization {
            do {
                async let renderedChatTokens: Int? = chatTransport?(
                    PromptBudgetGuardChatRequest(
                        serverPort: serverPort,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        thinkingEnabled: thinkingEnabled,
                        timeoutSeconds: 1.0
                    )
                )
                async let userTokens = transport(
                    PromptBudgetGuardRequest(
                        serverPort: serverPort,
                        content: userPrompt,
                        timeoutSeconds: 0.25
                    )
                )
                let resolvedChatTokens = try await renderedChatTokens
                let resolvedUserTokens = try await userTokens
                exactChatPromptTokens = resolvedChatTokens
                if let resolvedChatTokens {
                    exactSystemTokens = max(0, resolvedChatTokens - resolvedUserTokens)
                } else {
                    exactSystemTokens = try await transport(
                        PromptBudgetGuardRequest(
                            serverPort: serverPort,
                            content: systemPrompt,
                            timeoutSeconds: 0.25
                        )
                    )
                }
                exactUserTokens = resolvedUserTokens
                warning = nil
            } catch {
                exactChatPromptTokens = nil
                exactSystemTokens = nil
                exactUserTokens = nil
                warning = "PromptBudgetGuard tokenization fallback: \(error.localizedDescription)"
            }
        } else {
            exactChatPromptTokens = nil
            exactSystemTokens = nil
            exactUserTokens = nil
            warning = nil
        }

        let systemTokens = exactSystemTokens ?? estimatedTextTokens(systemPrompt: systemPrompt, userPrompt: "")
        let userTokens = exactUserTokens ?? estimatedTextTokens(systemPrompt: "", userPrompt: userPrompt)
        let textPromptTokens = exactChatPromptTokens ?? (systemTokens + userTokens)
        let currentPromptTokens = textPromptTokens + imageTokens

        guard currentPromptTokens > allowedPromptTokens else {
            return PromptBudgetGuardResult(
                userPrompt: userPrompt,
                wasTruncated: false,
                warning: warning,
                promptTokensEstimate: textPromptTokens,
                imageTokensEstimate: imageTokens
            )
        }

        let allowedUserTokens = max(0, allowedPromptTokens - systemTokens - imageTokens)
        let truncatedPrompt: String
        let verifiedUserTokens: Int?

        if allowedUserTokens == 0 || userPrompt.isEmpty {
            truncatedPrompt = ""
            verifiedUserTokens = 0
        } else if exactUserTokens != nil {
            let tokenized = await truncatedPromptUsingTokenization(
                userPrompt: userPrompt,
                exactUserTokens: userTokens,
                allowedUserTokens: allowedUserTokens,
                serverPort: serverPort,
                transport: transport
            )
            truncatedPrompt = tokenized.prompt
            verifiedUserTokens = tokenized.verifiedTokens
        } else {
            truncatedPrompt = truncatedPromptUsingHeuristic(
                userPrompt: userPrompt,
                allowedUserTokens: allowedUserTokens
            )
            verifiedUserTokens = nil
        }

        let finalUserTokens: Int
        if let verifiedUserTokens {
            finalUserTokens = verifiedUserTokens
        } else if exactUserTokens != nil {
            do {
                finalUserTokens = try await transport(
                    PromptBudgetGuardRequest(
                        serverPort: serverPort,
                        content: truncatedPrompt,
                        timeoutSeconds: 0.25
                    )
                )
            } catch {
                finalUserTokens = estimatedTextTokens(systemPrompt: "", userPrompt: truncatedPrompt)
            }
        } else {
            finalUserTokens = estimatedTextTokens(systemPrompt: "", userPrompt: truncatedPrompt)
        }

        let verifiedPromptTokens: Int
        if let chatTransport, truncatedPrompt != userPrompt {
            do {
                verifiedPromptTokens = try await chatTransport(
                    PromptBudgetGuardChatRequest(
                        serverPort: serverPort,
                        systemPrompt: systemPrompt,
                        userPrompt: truncatedPrompt,
                        thinkingEnabled: thinkingEnabled,
                        timeoutSeconds: 1.0
                    )
                )
            } catch {
                verifiedPromptTokens = systemTokens + finalUserTokens
            }
        } else {
            verifiedPromptTokens = systemTokens + finalUserTokens
        }

        return PromptBudgetGuardResult(
            userPrompt: truncatedPrompt,
            wasTruncated: truncatedPrompt != userPrompt,
            warning: warning,
            promptTokensEstimate: verifiedPromptTokens,
            imageTokensEstimate: imageTokens
        )
    }

    static func defaultImageMaxDimension(for imagePath: String?) -> Int? {
        guard imagePath != nil else { return nil }
        return imageMaxDimensionLadder.first
    }

    nonisolated static func heuristicEstimate(
        charCount: Int,
        imageWidth: Int?,
        imageHeight: Int?
    ) -> Int {
        let textTokens = max(0, charCount / 4)
        let imageTokens: Int
        if let imageWidth, let imageHeight, imageWidth > 0, imageHeight > 0 {
            imageTokens = ((imageWidth + 511) / 512) * ((imageHeight + 511) / 512) * 256
        } else {
            imageTokens = 0
        }
        return textTokens + imageTokens
    }

    nonisolated static func estimatedImageTokens(for imagePath: String) -> Int {
        guard
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return 0
        }
        return estimatedImageTokens(
            imageWidth: width,
            imageHeight: height,
            maxDimension: imageMaxDimensionLadder.first
        )
    }

    nonisolated private static func estimatedTextTokens(systemPrompt: String, userPrompt: String) -> Int {
        max(0, (systemPrompt.count + userPrompt.count) / 4)
    }

    nonisolated private static func estimatedImageTokens(
        imageWidth: Int,
        imageHeight: Int,
        maxDimension: Int?
    ) -> Int {
        let dimensions = scaledImageDimensions(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            maxDimension: maxDimension
        )
        return heuristicEstimate(
            charCount: 0,
            imageWidth: dimensions.width,
            imageHeight: dimensions.height
        )
    }

    nonisolated private static func scaledImageDimensions(
        imageWidth: Int,
        imageHeight: Int,
        maxDimension: Int?
    ) -> (width: Int, height: Int) {
        guard let maxDimension,
              imageWidth > 0,
              imageHeight > 0,
              max(imageWidth, imageHeight) > maxDimension
        else {
            return (max(0, imageWidth), max(0, imageHeight))
        }

        let scale = Double(maxDimension) / Double(max(imageWidth, imageHeight))
        return (
            width: max(1, Int((Double(imageWidth) * scale).rounded(.down))),
            height: max(1, Int((Double(imageHeight) * scale).rounded(.down)))
        )
    }

    nonisolated private static func recommendedImageSizing(
        imagePath: String?,
        promptTokens: Int,
        ctxSize: Int,
        maxTokens: Int,
        reserve: Int,
        maxCtxGrowth: Int
    ) -> (imageMaxDimension: Int?, estimatedImageTokens: Int) {
        guard
            let imagePath,
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return (nil, 0)
        }

        for maxDimension in imageMaxDimensionLadder {
            let imageTokens = estimatedImageTokens(
                imageWidth: width,
                imageHeight: height,
                maxDimension: maxDimension
            )
            let requiredCtx = promptTokens + imageTokens + reserve + maxTokens
            if requiredCtx <= ctxSize + maxCtxGrowth {
                return (maxDimension, imageTokens)
            }
        }

        let smallest = imageMaxDimensionLadder.last
        let imageTokens = estimatedImageTokens(
            imageWidth: width,
            imageHeight: height,
            maxDimension: smallest
        )
        return (smallest, imageTokens)
    }

    private static func truncatedPromptUsingHeuristic(
        userPrompt: String,
        allowedUserTokens: Int
    ) -> String {
        guard !userPrompt.isEmpty, allowedUserTokens > 0 else { return "" }
        let allowedChars = min(userPrompt.count, allowedUserTokens * 4)
        return String(userPrompt.prefix(allowedChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatedPromptUsingTokenization(
        userPrompt: String,
        exactUserTokens: Int,
        allowedUserTokens: Int,
        serverPort: Int,
        transport: TokenizeTransport
    ) async -> (prompt: String, verifiedTokens: Int?) {
        guard !userPrompt.isEmpty, allowedUserTokens > 0, exactUserTokens > 0 else {
            return ("", 0)
        }

        // Last-resort fallback only: after image downscaling and ctx growth have already
        // been tried, preserve the prefix and trim only the volatile tail.
        let safeTargetTokens = max(1, allowedUserTokens - max(8, allowedUserTokens / 20))
        let estimatedCharsPerToken = Double(userPrompt.count) / Double(exactUserTokens)
        let estimatedChars = min(
            userPrompt.count,
            max(1, Int(Double(safeTargetTokens) * estimatedCharsPerToken))
        )
        let candidate = String(userPrompt.prefix(estimatedChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let verifiedTokens = try await transport(
                PromptBudgetGuardRequest(
                    serverPort: serverPort,
                    content: candidate,
                    timeoutSeconds: 0.25
                )
            )
            if verifiedTokens <= allowedUserTokens {
                return (candidate, verifiedTokens)
            }
        } catch {
            return (
                truncatedPromptUsingHeuristic(
                    userPrompt: userPrompt,
                    allowedUserTokens: allowedUserTokens
                ),
                nil
            )
        }

        return (
            truncatedPromptUsingHeuristic(
                userPrompt: userPrompt,
                allowedUserTokens: allowedUserTokens
            ),
            nil
        )
    }
}
