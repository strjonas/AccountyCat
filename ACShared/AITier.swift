//
//  AITier.swift
//  ACShared
//
//  Moved from AC/Models/ACModels.swift so both AC and ACInspector can reference it.
//

import Foundation

/// User-facing intelligence tier. Stored in ACState and mapped to concrete model
/// identifiers in AppController.updateAITier(_:). Economy/Default/Smartest are shown
/// in onboarding and Settings → AI; the underlying model IDs are an implementation detail.
enum AITier: String, Codable, CaseIterable, Sendable {
    case economy
    case balanced   // displayed as "Default"
    case smartest

    var displayName: String {
        switch self {
        case .economy:  return "Economy"
        case .balanced: return "Default"
        case .smartest: return "Smartest"
        }
    }

    var description: String {
        switch self {
        case .economy:
            return "Fast and lightweight. Less compute offline or API usage with BYOK. Best for minimal overhead or limited resources."
        case .balanced:
            return "Balanced. Recommended for most users. Strong enough to understand context well, efficient enough to run all day."
        case .smartest:
            return "Best reasoning. Understands nuance better, fewer false nudges, and more convincing when you explain yourself."
        }
    }

    var offlineDescription: String {
        switch self {
        case .economy:
            return "Qwen 3.5 4B. ~2–3 GB RAM. Safe for 8GB machines."
        case .balanced:
            return "Qwen 3.5 9B. ~5–7 GB RAM. Better reasoning, recommended for most."
        case .smartest:
            return "Qwen 3.6 27B. ~15–18 GB RAM. Best local reasoning."
        }
    }

    var onlineDescription: String {
        switch self {
        case .economy:
            return "Nemotron-3 Super 120B (text), Qwen 3.5 9B (images). ~$0.10–$0.25/mo."
        case .balanced:
            return "DeepSeek V4 Flash (text), Gemma 4 31B (images). ~$0.20–$0.50/mo."
        case .smartest:
            return "DeepSeek V4 Flash (text), Gemini 3 Flash (images). ~$0.50–$1.00/mo."
        }
    }

    // MARK: BYOK (OpenRouter) model identifiers per tier

    var byokModelIdentifier: String {
        switch self {
        case .economy:  return "qwen/qwen3.5-9b"
        case .balanced: return "google/gemma-4-31b-it"
        case .smartest: return "google/gemini-3-flash-preview"
        }
    }

    /// Text-only optimized model for OpenRouter
    var byokModelIdentifierText: String {
        switch self {
        case .economy:  return "nvidia/nemotron-3-super-120b-a12b"
        case .balanced: return "deepseek/deepseek-v4-flash"
        case .smartest: return "deepseek/deepseek-v4-flash"
        }
    }

    /// Image/vision optimized model for OpenRouter
    var byokModelIdentifierImage: String {
        switch self {
        case .economy:  return "qwen/qwen3.5-9b"
        case .balanced: return "google/gemma-4-31b-it"
        case .smartest: return "google/gemini-3-flash-preview"
        }
    }

    var byokCostEstimate: String {
        switch self {
        case .economy:  return "~$0.10-0.40/mo"
        case .balanced: return "~$0.20-0.80/mo"
        case .smartest: return "~$0.95–1.90/mo"
        }
    }

    // MARK: Local (offline) model identifiers per tier

    var localModelOverride: String {
        switch self {
        case .economy:  return "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL"
        case .balanced: return "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        case .smartest: return "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL"
        }
    }

    /// Text-only optimized model for local (same as default for now, but can be customized)
    var localModelIdentifierText: String {
        switch self {
        case .economy:  return "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL"
        case .balanced: return "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        case .smartest: return "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL"
        }
    }

    /// Image/vision optimized model for local (same as default for now, but can be customized)
    var localModelIdentifierImage: String {
        switch self {
        case .economy:  return "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL"
        case .balanced: return "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
        case .smartest: return "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL"
        }
    }

    var localModelDisplayName: String {
        switch self {
        case .economy:  return "Qwen 3.5 4B"
        case .balanced: return "Qwen 3.5 9B"
        case .smartest: return "Qwen 3.6 27B"
        }
    }

    var localRAMEstimate: String {
        switch self {
        case .economy:  return "~2-3 GB RAM"
        case .balanced: return "~5-7 GB RAM"
        case .smartest: return "~15-18 GB RAM"
        }
    }
}
