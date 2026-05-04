//
//  AITab.swift
//  AC
//
//  Mode pills + intensity slider + tier picker + OR key + local models.
//

import SwiftUI

struct AITab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var showVisionInfo = false
    @State private var showAdvanced = false

    private var config: MonitoringConfiguration { controller.state.monitoringConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Vision
            HStack {
                sectionLabel("vision")
                Spacer()
                Button {
                    withAnimation(.acSnap) { showVisionInfo.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }

            if showVisionInfo {
                Text("AC takes periodic screenshots and analyzes them to understand what you're doing — without sending anything to the cloud (in local mode). Screenshots are analyzed and immediately discarded; only the structured result is kept.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -10)
            }

            sectionLabel("how actively should AC watch")
            intensitySlider
            Text("calm = fewer checks, lower cost/compute. sharp = catches drift faster, more prompts.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            Divider().opacity(0.3)

            // Mode
            sectionLabel("how AC thinks")
            modePills

            // Tier
            sectionLabel("intelligence tier")
            tierPicker
            Text("AC uses different models for vision vs text — no need to pick them yourself.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            // Backend-specific sections
            if config.inferenceBackend == .openRouter {
                orKeySection
            } else {
                localModelSection
            }

            Divider().opacity(0.3)

            // Advanced
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("advanced mode")
                        .font(.ac(12, weight: .medium))
                        .foregroundStyle(Color.acTextPrimary)
                    Text("choose specific models yourself")
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $showAdvanced)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if showAdvanced {
                Text("advanced model selection coming in a future build.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .fill(Color.acSurfaceInset)
                    )
            }
        }
    }

    // MARK: - Intensity slider

    private var intensitySlider: some View {
        let value = cadenceSliderValue
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("calm")
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("sharp")
                    .font(.ac(10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.acSurfaceInset)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: geo.size.width * value, height: 4)
                    Circle()
                        .fill(accent)
                        .frame(width: 14, height: 14)
                        .shadow(color: accent.opacity(0.3), radius: 4)
                        .offset(x: geo.size.width * value - 7)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    let pct = max(0, min(1, gesture.location.x / geo.size.width))
                                    setCadenceFromSlider(pct)
                                }
                        )
                }
            }
            .frame(height: 14)
        }
    }

    private var cadenceSliderValue: CGFloat {
        switch config.cadenceMode {
        case .gentle:   return 0.0
        case .balanced: return 0.5
        case .sharp:    return 1.0
        }
    }

    private func setCadenceFromSlider(_ pct: CGFloat) {
        let mode: MonitoringCadenceMode
        if pct < 0.33 { mode = .gentle }
        else if pct < 0.66 { mode = .balanced }
        else { mode = .sharp }
        controller.updateMonitoringCadenceMode(mode)
    }

    // MARK: - Mode pills

    private var modePills: some View {
        HStack(spacing: 8) {
            modePill(
                id: .local,
                label: "Local",
                sub: "private · free",
                disabled: false
            )
            modePill(
                id: .openRouter,
                label: "OpenRouter",
                sub: "bring your own key",
                disabled: false
            )
        }
    }

    private func modePill(id: MonitoringInferenceBackend, label: String, sub: String, disabled: Bool) -> some View {
        let isSelected = config.inferenceBackend == id
        return Button {
            guard !disabled else { return }
            controller.updateMonitoringInferenceBackend(id)
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.ac(12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : (isSelected ? accent : Color.acTextPrimary))
                Text(sub)
                    .font(.ac(10))
                    .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(isSelected && !disabled ? accent.opacity(0.10) : Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(isSelected && !disabled ? accent.opacity(0.4) : Color.acHairline, lineWidth: 1)
                    )
            )
            .opacity(disabled ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Tier picker

    private var tierPicker: some View {
        VStack(spacing: 6) {
            ForEach(AITier.allCases, id: \.self) { tier in
                let isSelected = controller.currentAITier == tier
                Button {
                    controller.updateAITier(tier)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(isSelected ? accent : Color.acHairline, lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                            if isSelected {
                                Circle()
                                    .fill(accent)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tier.displayName)
                                .font(.ac(12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(Color.acTextPrimary)
                            Text(tier.description)
                                .font(.ac(10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.08) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                    .stroke(isSelected ? accent.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - OpenRouter key

    private var orKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3)
            sectionLabel("openrouter key")
            Text("paste your OpenRouter API key. AC will pick the right models per tier.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            OpenRouterKeyField(compact: true)
                .environmentObject(controller)
        }
    }

    // MARK: - Local model storage

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3)
            sectionLabel("installed models")
            ContentView.LocalModelStorageSection(onDelete: { })
                .environmentObject(controller)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ac(11, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.7))
            .textCase(.lowercase)
    }
}
