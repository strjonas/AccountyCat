//
//  OpenRouterKeyField.swift
//  AC
//

import AppKit
import SwiftUI

/// Shared API key field used by the onboarding wizard and Settings → AI.
/// Provides inline guidance for users who don't have an OpenRouter account yet.
struct OpenRouterKeyField: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    /// `compact` trims the header label size for use inside existing SettingsSections.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
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
                    NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!)
                } label: {
                    HStack(spacing: 3) {
                        Text("Get a key")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.ac(10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }

            // Key field
            SecureField(
                "Paste your sk-or-… key",
                text: Binding(
                    get: { controller.onlineAPIKeyDraft },
                    set: { controller.updateOnlineAPIKey($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))

            // Status / guidance
            if controller.hasOnlineAPIKeyConfigured {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Key saved to macOS Keychain · Model: \(AppController.shortModelName(for: controller.state.monitoringConfiguration.onlineModelIdentifier))")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                }
            } else {
                // Inline quick-start guide shown until a key is entered
                VStack(alignment: .leading, spacing: 4) {
                    Text("No account yet? It takes 2 minutes:")
                        .font(.ac(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        guidanceStep("1", "Go to openrouter.ai and sign up")
                        guidanceStep("2", "Open Settings → Keys → Create Key")
                        guidanceStep("3", "Paste the key above and pick your model tier in AC")
                    }
                    Button("openrouter.ai/keys →") {
                        NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .font(.ac(10, weight: .medium))
                    .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(Color.acSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .stroke(Color.acHairline, lineWidth: 1)
                        )
                )
            }
        }
    }

    private func guidanceStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .frame(width: 14, height: 14)
                .background(Circle().fill(accent.opacity(0.12)))
            Text(text)
                .font(.ac(10))
                .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
