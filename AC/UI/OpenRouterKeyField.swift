//
//  OpenRouterKeyField.swift
//  AC
//

import AppKit
import SwiftUI

/// Shared label-row + secure key field used by both the onboarding card and
/// the Settings → Mode section. Keeps the placeholder, the openrouter.ai/keys
/// link, and the Keychain footnote in one place so they don't drift.
struct OpenRouterKeyField: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    /// `compact` uses smaller label sizing for the Settings section header,
    /// where the field sits inside an existing `SettingsSection` title.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !compact {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Text("OpenRouter API key")
                    .font(.ac(compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(compact ? .secondary : Color.acTextPrimary)
                Spacer(minLength: 0)
                Button {
                    if let url = URL(string: "https://openrouter.ai/keys") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Get a free key")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.ac(10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }

            SecureField(
                "Paste your sk-or-… key",
                text: Binding(
                    get: { controller.onlineAPIKeyDraft },
                    set: { controller.updateOnlineAPIKey($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))

            Text(controller.hasOnlineAPIKeyConfigured
                 ? "Saved in your macOS Keychain. Model: \(AppController.shortModelName(for: controller.state.monitoringConfiguration.onlineModelIdentifier))."
                 : "Stored only in your macOS Keychain. Free Gemma model is selected by default.")
                .font(.ac(10))
                .foregroundStyle(.secondary)
        }
    }
}
