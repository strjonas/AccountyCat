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
    @State private var showDeleteModelConfirm = false
    @State private var modelToDelete: InstalledLocalModel?
    @State private var advancedTextModelID = ""
    @State private var advancedImageModelID = ""

    private var config: MonitoringConfiguration { controller.state.monitoringConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Vision toggle + info
            HStack(spacing: 8) {
                sectionLabel("vision")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.visionEnabled },
                    set: { controller.updateVisionEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
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
                    Text("Advanced mode")
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
                advancedModelSection
            }
        }
        .alert("Delete model?", isPresented: $showDeleteModelConfirm) {
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    deleteModel(model)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let model = modelToDelete,
               model.cachePath == controller.selectedInstalledModel?.cachePath {
                Text("This is your current active model. Deleting it will switch AC to the next available model.")
            } else {
                Text("This will free up storage space.")
            }
        }
        .onAppear {
            advancedTextModelID = config.onlineModelIdentifierText ?? config.onlineModelIdentifier
            advancedImageModelID = config.onlineModelIdentifierImage ?? config.onlineModelIdentifier
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
            managedPill
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

    private var managedPill: some View {
        Button { } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Managed")
                        .font(.ac(12, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
                Text("coming soon")
                    .font(.ac(10))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.md, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .opacity(0.6)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("Managed mode is coming soon. Sign up at accountycat.com/managed-waitlist")
        .contextMenu {
            Button("Join waitlist…") {
                NSWorkspace.shared.open(URL(string: "https://accountycat.com/managed-waitlist")!)
            }
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

            let installed = controller.installedManagedModels
            let selected = controller.selectedInstalledModel

            if installed.isEmpty {
                Text("No AC-downloaded local models found yet.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(installed) { model in
                        let isActive = model.cachePath == selected?.cachePath
                        HStack(spacing: 10) {
                            Text("◈")
                                .font(.system(size: 12))
                                .foregroundStyle(isActive ? accent : Color.acTextPrimary.opacity(0.4))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(AppController.shortModelName(for: model.modelIdentifier))
                                        .font(.ac(12, weight: isActive ? .semibold : .medium))
                                        .foregroundStyle(Color.acTextPrimary)
                                    if isActive {
                                        Text("active")
                                            .font(.ac(9, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule(style: .continuous).fill(accent))
                                    }
                                }
                                Text(model.modelIdentifier)
                                    .font(.ac(10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                modelToDelete = model
                                showDeleteModelConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.red.opacity(0.72))
                                    .frame(width: 26, height: 26)
                                    .background(
                                        Circle()
                                            .fill(Color.red.opacity(0.08))
                                            .overlay(Circle().stroke(Color.red.opacity(0.18), lineWidth: 1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .fill(isActive ? accent.opacity(0.06) : Color.acSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                        .stroke(isActive ? accent.opacity(0.2) : Color.acHairline, lineWidth: 1)
                                )
                        )
                    }
                }
            }
        }
    }

    private func deleteModel(_ model: InstalledLocalModel) {
        controller.selectInstalledModel(cachePath: model.cachePath)
        controller.deleteManagedModels()
        modelToDelete = nil
    }

    // MARK: - Advanced model selection

    private var advancedModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the models AC uses for text and image analysis.")
                .font(.acCaption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("text model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                TextField(
                    config.inferenceBackend == .openRouter
                        ? "e.g. openai/gpt-4o-mini"
                        : "e.g. gemma-4b-it-q4_K_M",
                    text: $advancedTextModelID
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { saveAdvancedModels() }

                Text("image / vision model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                TextField(
                    config.inferenceBackend == .openRouter
                        ? "e.g. openai/gpt-4o"
                        : "e.g. moondream-2b-llava-ft-mlx",
                    text: $advancedImageModelID
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { saveAdvancedModels() }

                Text(config.inferenceBackend == .openRouter
                     ? "Paste the OpenRouter model ID (provider/model-name)."
                     : "Paste the Hugging Face or llama.cpp model identifier.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }

            if advancedTextModelID != (config.onlineModelIdentifierText ?? config.onlineModelIdentifier)
                || advancedImageModelID != (config.onlineModelIdentifierImage ?? config.onlineModelIdentifier) {
                HStack {
                    Spacer()
                    Button("Save models") { saveAdvancedModels() }
                        .buttonStyle(ACPrimaryButton())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurfaceInset)
        )
    }

    private func saveAdvancedModels() {
        let trimmedText = advancedTextModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = advancedImageModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedImage.isEmpty else { return }

        if config.inferenceBackend == .openRouter {
            controller.updateOnlineModelIdentifierText(trimmedText)
            controller.updateOnlineModelIdentifierImage(trimmedImage)
        } else {
            controller.updateLocalModelIdentifierText(trimmedText)
            controller.updateLocalModelIdentifierImage(trimmedImage)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}
