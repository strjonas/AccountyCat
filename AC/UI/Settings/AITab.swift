//
//  AITab.swift
//  AC
//
//  Mode pills + intensity slider + tier picker + OR key + local models.
//

import SwiftUI
import UniformTypeIdentifiers

struct AITab: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.acAccent) private var accent

    @State private var showVisionInfo = false
    @State private var showAdvanced = false
    @State private var showEconomyInfo = false
    @State private var showZDRInfo = false
    @State private var showZDRDisableConfirm = false
    @State private var zdrEnabled = OnlineProviderRouting.isZDREnforced()
    @State private var showDeleteModelConfirm = false
    @State private var modelToDeleteIdentifier: String?
    @State private var modelToDeleteName: String?
    @State private var modelToDeleteIsCustom = false
    @State private var showAddCustomModel = false
    @State private var addModelSource: AddModelSource = .huggingFace
    @State private var pickedLocalFilePath = ""
    @State private var modelToRenameIdentifier: String?
    @State private var renameDraft = ""
    @State private var advancedTextModelID = ""
    @State private var advancedImageModelID = ""
    @State private var advancedLocalModelName = ""

    /// Where a new custom local model comes from: downloaded from Hugging Face, or a
    /// `.gguf` file the user already has on disk (e.g. via Ollama) and just links.
    private enum AddModelSource: Hashable { case huggingFace, file }

    private var config: MonitoringConfiguration { controller.state.monitoringConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Vision + cadence card
            VStack(alignment: .leading, spacing: 0) {
                // Vision row
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { controller.visionEnabled },
                        set: { controller.updateVisionEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Vision")
                            .font(.ac(12, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                        Text("screenshots analyzed locally")
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                    }
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
                .padding(10)

                if showVisionInfo {
                    Text("AC takes periodic screenshots and analyzes them to understand what you're working on. Screenshots are discarded immediately — only the structured result is kept. In local mode nothing leaves your Mac. Disabling vision reduces token usage but AC will rely on app titles and window names alone, which can miss context.")
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }

                Divider().opacity(0.3)

                // Cadence row
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOW PERSISTENT SHOULD I BE?")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.06)
                        .foregroundStyle(Color.acTextPrimary.opacity(0.38))
                    cadencePills
                    Text(cadenceDescription)
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )

            Divider().opacity(0.3)

            // Mode
            sectionLabel("how AC thinks")
            modePills

            ramBanner

            // Tier
            sectionLabel("intelligence tier")
            tierPicker

            if let notice = controller.modelMismatchNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(accent)
                    Text(notice)
                        .font(.acCaption)
                        .foregroundStyle(Color.acTextPrimary.opacity(0.85))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .fill(accent.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                                .stroke(accent.opacity(0.25), lineWidth: 1)
                        )
                )
            }

            // Backend-specific sections
            if config.inferenceBackend == .openRouter {
                orKeySection
            } else {
                runtimeUpdateBanner
                localModelSection
            }

            // Advanced (OpenRouter only — local custom models are added inline
            // under the model list, so a separate "advanced" surface would just
            // scatter related controls).
            if config.inferenceBackend == .openRouter {
                Divider().opacity(0.3)
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
        }
        .alert(modelToDeleteIsCustom ? "Remove model?" : "Delete model?", isPresented: $showDeleteModelConfirm) {
            Button(modelToDeleteIsCustom ? "Remove" : "Delete", role: .destructive) {
                if let modelToDeleteIdentifier {
                    if modelToDeleteIsCustom {
                        controller.removeCustomLocalModel(identifier: modelToDeleteIdentifier)
                    } else {
                        deleteModel(identifier: modelToDeleteIdentifier)
                    }
                }
                modelToDeleteIsCustom = false
            }
            Button("Cancel", role: .cancel) { modelToDeleteIsCustom = false }
        } message: {
            let isLinkedFile = modelToDeleteIdentifier.map(RuntimeSetupService.isLocalFileModelIdentifier) ?? false
            if let modelToDeleteIdentifier,
               modelToDeleteIdentifier == controller.activeLocalModelIdentifier() {
                Text("This is your current active model. \(modelToDeleteIsCustom ? "Removing" : "Deleting") it will switch AC to the next available model.")
            } else if let modelToDeleteName {
                if isLinkedFile {
                    Text("This removes the link to \(modelToDeleteName). Your file stays on disk.")
                } else {
                    Text(modelToDeleteIsCustom
                         ? "This removes \(modelToDeleteName) and deletes its downloaded files."
                         : "This will delete \(modelToDeleteName) from local storage.")
                }
            } else {
                Text("This will free up storage space.")
            }
        }
        .onAppear {
            resetAdvancedModelDrafts()
        }
        .onChange(of: config.inferenceBackend) { _, _ in
            resetAdvancedModelDrafts()
            resetAddCustomModel()
        }
    }

    // MARK: - Cadence pills

    private var cadencePills: some View {
        HStack(spacing: 4) {
            ForEach([MonitoringCadenceMode.gentle, .balanced, .sharp], id: \.self) { mode in
                let isSelected = config.cadenceMode == mode
                Button {
                    controller.updateMonitoringCadenceMode(mode)
                    controller.updateTitleLengthForTextOnly(mode.recommendedTitleLengthForTextOnly)
                } label: {
                    Text(cadenceModeLabel(mode))
                        .font(.ac(11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.acTextPrimary.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? accent : Color.acSurfaceInset)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(isSelected ? accent.opacity(0.5) : Color.acHairline, lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cadenceModeLabel(_ mode: MonitoringCadenceMode) -> String {
        switch mode {
        case .gentle:   return "calm"
        case .balanced: return "balanced"
        case .sharp:    return "sharp"
        }
    }

    private var cadenceDescription: String {
        switch config.cadenceMode {
        case .gentle:   return "nudges rarely — gives you room to breathe, reacts slower to drift"
        case .balanced: return "nudges when you clearly drift — good default for most"
        case .sharp:    return "catches drift quickly, nudges more often — more model calls so slightly higher cost"
        }
    }

    // MARK: - Mode pills

    private var modePills: some View {
        HStack(spacing: 8) {
            modePill(
                id: .openRouter,
                label: "OpenRouter",
                sub: "bring your own key",
                badge: AITier.byokRecommendedOverLocal ? "★ Recommended" : nil,
                disabled: false
            )
            modePill(
                id: .local,
                label: "Local",
                sub: "private · offline",
                disabled: false
            )
            managedPill
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

    private func modePill(id: MonitoringInferenceBackend, label: String, sub: String, badge: String? = nil, disabled: Bool) -> some View {
        let isSelected = config.inferenceBackend == id
        return Button {
            guard !disabled else { return }
            controller.updateMonitoringInferenceBackend(id)
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.ac(12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : (isSelected ? accent : Color.acTextPrimary))
                if let badge, !isSelected {
                    Text(badge)
                        .font(.ac(9, weight: .semibold))
                        .foregroundStyle(accent)
                }
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

    // MARK: - Hardware recommendation

    @ViewBuilder
    private var ramBanner: some View {
        if config.inferenceBackend == .local, AITier.byokRecommendedOverLocal {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                Text("On this Mac we recommend OpenRouter — smarter models, less RAM pressure. You can ignore this, it's your call.")
                    .font(.ac(10))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(accent.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                            .stroke(accent.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Tier picker

    @ViewBuilder
    private var tierPicker: some View {
        if config.inferenceBackend == .local {
            localModelCards
        } else {
            onlineTierPicker
        }
    }

    private var onlineTierPicker: some View {
        VStack(spacing: 6) {
            ForEach(AITier.allCases, id: \.self) { tier in
                let isSelected = controller.currentAITier == tier
                let isRecommended = tier == .balanced
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
                            HStack(spacing: 4) {
                                Text(tier.displayName)
                                    .font(.ac(12, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(Color.acTextPrimary)
                                if tier == .economy {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.secondary.opacity(0.5))
                                        .onTapGesture { showEconomyInfo = true }
                                        .popover(isPresented: $showEconomyInfo, arrowEdge: .top) {
                                            Text(AITier.economyTierQualityNote)
                                                .font(.ac(11))
                                                .foregroundStyle(Color.acTextPrimary)
                                                .padding(12)
                                                .frame(width: 220)
                                        }
                                }
                                if isRecommended {
                                    Text("recommended")
                                        .font(.ac(8, weight: .semibold))
                                        .foregroundStyle(accent.opacity(0.7))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(accent.opacity(0.10))
                                                .overlay(
                                                    Capsule(style: .continuous)
                                                        .stroke(accent.opacity(0.2), lineWidth: 0.5)
                                                )
                                        )
                                }
                            }
                            Text(tier.description)
                                .font(.ac(10))
                                .foregroundStyle(.secondary)
                            if config.inferenceBackend == .openRouter {
                                Text(tierModelSummary(for: tier))
                                    .font(.ac(10, weight: .medium))
                                    .foregroundStyle(Color.acTextPrimary.opacity(0.65))
                                    .padding(.top, 1)
                            }
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

    private var localModelCards: some View {
        VStack(spacing: 6) {
            ForEach(localModelCardDescriptors) { card in
                localModelCard(card)
            }
            localCustomModelAdder
                .padding(.top, 2)
        }
    }

    // MARK: - Inline custom local model adder

    /// A collapsed "+ Add a custom model" affordance that expands inline, right
    /// under the model list it feeds — so the form and the card it produces live
    /// in the same place instead of being split across an Advanced toggle.
    @ViewBuilder
    private var localCustomModelAdder: some View {
        if showAddCustomModel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a custom model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)

                TextField("Name (e.g. Gemma 12B)", text: $advancedLocalModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.ac(11))
                    .onSubmit { saveLocalCustomModel() }

                HStack(spacing: 6) {
                    addSourcePill("Hugging Face", source: .huggingFace)
                    addSourcePill("Local file", source: .file)
                }

                if addModelSource == .huggingFace {
                    TextField("unsloth/gemma-4-12b-it-GGUF:Q4_K_M", text: $advancedTextModelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { saveLocalCustomModel() }
                    Text("Paste a Hugging Face GGUF repo, optionally followed by :QUANT. Adding it creates a card you can then download.")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        chooseLocalModelFile()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .semibold))
                            Text(pickedLocalFilePath.isEmpty ? "Choose .gguf file…" : "Choose a different file…")
                                .font(.ac(11, weight: .medium))
                        }
                        .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    if !pickedLocalFilePath.isEmpty {
                        Text(pickedLocalFilePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("Link a .gguf you already have (e.g. from Ollama or a manual download). AC uses it in place — no second copy, no re-download.")
                        .font(.ac(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") {
                        withAnimation(.acSnap) { resetAddCustomModel() }
                    }
                    .buttonStyle(.plain)
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(.secondary)
                    Button(addModelSource == .file ? "Add" : "Add card") { saveLocalCustomModel() }
                        .buttonStyle(ACPrimaryButton())
                        .disabled(newCustomModelIdentifier.isEmpty)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .fill(Color.acSurfaceInset)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Button {
                withAnimation(.acSnap) { showAddCustomModel = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add a custom model")
                        .font(.ac(11, weight: .medium))
                }
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .strokeBorder(
                            accent.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func addSourcePill(_ label: String, source: AddModelSource) -> some View {
        let isSelected = addModelSource == source
        return Button {
            withAnimation(.acSnap) { addModelSource = source }
        } label: {
            Text(label)
                .font(.ac(10, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.acTextPrimary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Color.acSurface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? accent.opacity(0.5) : Color.acHairline, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rename popover

    /// A small, styled inline editor anchored to the card's pencil — nicer than the
    /// stock rename alert and keeps the edit visually attached to the model it renames.
    private func renamePopover(for identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename model")
                .font(.ac(11, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.ac(12))
                .frame(width: 200)
                .onSubmit { commitRename(identifier: identifier) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { modelToRenameIdentifier = nil }
                    .buttonStyle(.plain)
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("Save") { commitRename(identifier: identifier) }
                    .buttonStyle(ACPrimaryButton())
            }
        }
        .padding(14)
    }

    private func commitRename(identifier: String) {
        controller.renameCustomLocalModel(identifier: identifier, displayName: renameDraft)
        modelToRenameIdentifier = nil
    }

    private func saveLocalCustomModel() {
        let id = newCustomModelIdentifier
        guard !id.isEmpty else { return }
        controller.addCustomLocalModel(displayName: advancedLocalModelName, modelIdentifier: id)
        withAnimation(.acSnap) { resetAddCustomModel() }
    }

    /// The identifier a new custom model will use, depending on the chosen source:
    /// a Hugging Face GGUF repo id, or the absolute path of a linked `.gguf` file.
    private var newCustomModelIdentifier: String {
        switch addModelSource {
        case .huggingFace: return advancedTextModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file:        return pickedLocalFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func chooseLocalModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose a .gguf model file you already have on disk."
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedLocalFilePath = url.path
        // Pre-fill the name from the filename so the user usually just hits Add.
        if advancedLocalModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            advancedLocalModelName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func resetAddCustomModel() {
        showAddCustomModel = false
        addModelSource = .huggingFace
        advancedLocalModelName = ""
        advancedTextModelID = ""
        pickedLocalFilePath = ""
    }

    private var localModelCardDescriptors: [LocalModelCardDescriptor] {
        let defaults = AITier.allCases.map { tier in
            LocalModelCardDescriptor(
                title: tier.displayName,
                // Built-in tiers show only the friendly model name + RAM; the raw
                // Hugging Face id (e.g. unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL) is noise.
                subtitle: "",
                detail: "\(tier.localModelDisplayName) · \(tier.localRAMEstimate)",
                modelIdentifier: tier.localModelIdentifierText,
                tier: tier,
                isRecommended: tier == AITier.recommendedLocalTier()
            )
        }
        let defaultIDs = Set(defaults.map(\.modelIdentifier))
        let custom = controller.localCustomModelsForDisplay()
            .filter { !defaultIDs.contains($0.modelIdentifier) }
            .map { model in
                LocalModelCardDescriptor(
                    title: model.displayName,
                    subtitle: model.modelIdentifier,
                    // No "custom local model" filler — the name plus the technical id
                    // (HF repo or linked file path) below it is all the context needed.
                    detail: "",
                    modelIdentifier: model.modelIdentifier,
                    tier: nil,
                    isRecommended: false
                )
            }
        return defaults + custom
    }

    private func localModelCard(_ card: LocalModelCardDescriptor) -> some View {
        let activeIdentifier = controller.activeLocalModelIdentifier()
        let isSelected = activeIdentifier == card.modelIdentifier
        let isInstalled = controller.localModelInstalled(card.modelIdentifier)
        let isPending = controller.pendingLocalModelChange?.modelIdentifier == card.modelIdentifier
        let isDownloading = isPending && controller.installingRuntime

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
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
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(card.title)
                            .font(.ac(12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Color.acTextPrimary)
                            .lineLimit(1)
                        if card.tier == nil {
                            Button {
                                renameDraft = card.title
                                modelToRenameIdentifier = card.modelIdentifier
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Rename this model")
                            .popover(
                                isPresented: Binding(
                                    get: { modelToRenameIdentifier == card.modelIdentifier },
                                    set: { if !$0 { modelToRenameIdentifier = nil } }
                                ),
                                arrowEdge: .bottom
                            ) {
                                renamePopover(for: card.modelIdentifier)
                            }
                        }
                        if card.isRecommended {
                            localStatusBadge("recommended", tint: accent)
                        }
                        if isSelected {
                            localStatusBadge("active", tint: accent)
                        }
                    }
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .font(.ac(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !card.subtitle.isEmpty {
                        Text(card.subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.acTextPrimary.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                localModelCardControls(
                    card,
                    isInstalled: isInstalled,
                    isPending: isPending,
                    isDownloading: isDownloading
                )
            }

            if isPending {
                localModelDownloadProgress(card.modelIdentifier, isDownloading: isDownloading)
            } else if !isInstalled {
                let partialBytes = controller.localModelDownloadedBytes(card.modelIdentifier)
                if partialBytes > 0 {
                    Text("\(formatBytes(partialBytes)) already downloaded")
                        .font(.ac(10))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.58))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous))
        .onTapGesture {
            guard isInstalled else { return }
            controller.selectInstalledLocalModel(identifier: card.modelIdentifier, tier: card.tier)
        }
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(isSelected ? accent.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(isSelected ? accent.opacity(0.3) : Color.acHairline.opacity(0.6), lineWidth: 1)
                )
        )
    }

    private func localStatusBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.ac(8, weight: .semibold))
            .foregroundStyle(tint.opacity(0.75))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.10))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.2), lineWidth: 0.5)
                    )
            )
    }

    @ViewBuilder
    private func localModelCardControls(
        _ card: LocalModelCardDescriptor,
        isInstalled: Bool,
        isPending: Bool,
        isDownloading: Bool
    ) -> some View {
        let isCustom = card.tier == nil
        HStack(spacing: 6) {
            if isPending {
                iconButton(
                    systemName: isDownloading ? "pause.fill" : "play.fill",
                    tint: accent,
                    help: isDownloading ? "Pause download" : "Resume download"
                ) {
                    if isDownloading {
                        controller.pauseLocalModelDownload(identifier: card.modelIdentifier)
                    } else {
                        controller.resumeLocalModelDownload(identifier: card.modelIdentifier)
                    }
                }
                if isCustom {
                    // For a custom card, "stop" is the same as removing it — the
                    // user added it, so there's no built-in card to fall back to.
                    iconButton(systemName: "trash", tint: .red, help: "Remove custom model") {
                        controller.removeCustomLocalModel(identifier: card.modelIdentifier)
                    }
                } else {
                    iconButton(systemName: "xmark", tint: .red, help: "Stop and remove partial download") {
                        controller.stopLocalModelDownload(identifier: card.modelIdentifier)
                    }
                }
            } else if isInstalled {
                iconButton(systemName: "trash", tint: .red, help: isCustom ? "Remove custom model" : "Delete downloaded model") {
                    modelToDeleteIdentifier = card.modelIdentifier
                    modelToDeleteName = card.title
                    modelToDeleteIsCustom = isCustom
                    showDeleteModelConfirm = true
                }
            } else {
                iconButton(systemName: "arrow.down", tint: accent, help: "Download model") {
                    controller.startLocalModelDownload(identifier: card.modelIdentifier)
                }
                if isCustom {
                    // A custom card that never installed (e.g. the id didn't resolve
                    // on Hugging Face) can be removed outright — no confirm needed.
                    iconButton(systemName: "trash", tint: .red, help: "Remove custom model") {
                        controller.removeCustomLocalModel(identifier: card.modelIdentifier)
                    }
                }
            }
        }
    }

    private func iconButton(
        systemName: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.82))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(tint.opacity(0.08))
                        .overlay(Circle().stroke(tint.opacity(0.18), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func localModelDownloadProgress(_ identifier: String, isDownloading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if isDownloading, let progress = controller.setupProgressValue {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if isDownloading {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isDownloading ? downloadStatusText : pausedDownloadStatusText(for: identifier))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if isDownloading, let progress = controller.setupProgressValue {
                    Text("\(max(0, min(100, Int((progress * 100).rounded()))))%")
                } else if !isDownloading {
                    Text("paused")
                }
            }
            .font(.ac(10))
            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
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

    // MARK: - Local runtime update

    @ViewBuilder
    private var runtimeUpdateBanner: some View {
        if controller.updatingRuntime {
            // Update in progress — inline, the app stays usable on the old runtime.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.runtimeUpdateMessage ?? "Updating local runtime…")
                        .font(.ac(11))
                        .foregroundStyle(Color.acTextPrimary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("AC keeps running on the current runtime until this finishes. No restart needed.")
                    .font(.acCaption)
                    .foregroundStyle(Color.acTextPrimary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(runtimeBannerBackground)
        } else if controller.runtimeUpdateAvailable, !controller.installingRuntime {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(
                        "A newer local runtime is available. Updating can improve model support and fix models that returned unusable output."
                    )
                    .font(.ac(11))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Update runtime") {
                        controller.updateRuntime()
                    }
                    .buttonStyle(ACPrimaryButton())
                }
            }
            .padding(10)
            .background(runtimeBannerBackground)
        }
    }

    private var runtimeBannerBackground: some View {
        RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
            .fill(accent.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .stroke(accent.opacity(0.25), lineWidth: 1)
            )
    }

    // MARK: - Local model storage

    @ViewBuilder
    private var localModelSection: some View {
        if controller.setupErrorMessage != nil
            || controller.localModelStorageMessage != nil
            || controller.localModelStorageError != nil {
            VStack(alignment: .leading, spacing: 10) {
                Divider().opacity(0.3)
                sectionLabel("local model status")

                if let err = controller.setupErrorMessage {
                    localSetupErrorBanner(err)
                }

                if let message = controller.localModelStorageMessage {
                    Text(message)
                        .font(.acCaption)
                        .foregroundStyle(Color.acTextPrimary.opacity(0.72))
                }

                if let message = controller.localModelStorageError {
                    Text(message)
                        .font(.acCaption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
        }
    }

    /// "1.3 GB of 5.2 GB" when a total is known, otherwise downloaded-so-far or a
    /// generic message. Mirrors the live byte tracking driven during install.
    private var downloadStatusText: String {
        if let downloaded = controller.setupDownloadedBytes,
           let total = controller.setupTotalBytes, total > 0 {
            return "\(formatBytes(downloaded)) of \(formatBytes(total))"
        }
        if let downloaded = controller.setupDownloadedBytes, downloaded > 0 {
            return "Downloaded \(formatBytes(downloaded))…"
        }
        return controller.setupProgressMessage ?? "Downloading model…"
    }

    private func pausedDownloadStatusText(for identifier: String) -> String {
        let downloaded = controller.localModelDownloadedBytes(identifier)
        if downloaded > 0 {
            return "\(formatBytes(downloaded)) downloaded"
        }
        return "Download paused"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private func localSetupErrorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
                Text(message)
                    .font(.ac(11))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Try again") {
                    controller.setupErrorMessage = nil
                    controller.installRuntime(
                        modelIdentifier: controller.pendingLocalModelChange?.modelIdentifier
                    )
                }
                .buttonStyle(ACPrimaryButton())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func deleteModel(identifier: String) {
        controller.deleteLocalModel(identifier: identifier)
        modelToDeleteIdentifier = nil
        modelToDeleteName = nil
    }

    // MARK: - Advanced model selection

    private var advancedModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the OpenRouter models AC uses for text and image analysis.")
                .font(.acCaption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("text model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                TextField("e.g. openai/gpt-4o-mini", text: $advancedTextModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { saveAdvancedModels() }

                Text("image / vision model")
                    .font(.ac(11, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.7))
                TextField("e.g. openai/gpt-4o", text: $advancedImageModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { saveAdvancedModels() }

                Text("Paste OpenRouter model IDs in provider/model-name format.")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }

            if advancedModelsAreDirty {
                HStack {
                    Spacer()
                    Button("Save models") {
                        saveAdvancedModels()
                    }
                        .buttonStyle(ACPrimaryButton())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }

            Divider().opacity(0.3)
            zdrToggleRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurfaceInset)
        )
    }

    private var zdrToggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Zero Data Retention")
                            .font(.ac(12, weight: .medium))
                            .foregroundStyle(Color.acTextPrimary)
                        Text("(recommended)")
                            .font(.acCaption)
                            .foregroundStyle(.secondary)
                    }
                    Text(zdrEnabled
                         ? "Routes only to providers that don't log or retain your prompts."
                         : "Off — providers may log prompts. Use only if a model you need isn't on a ZDR endpoint.")
                        .font(.acCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { zdrEnabled },
                    set: { newValue in
                        if newValue {
                            zdrEnabled = true
                            OnlineProviderRouting.setZDREnforced(true)
                        } else {
                            showZDRDisableConfirm = true
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
                Button {
                    withAnimation(.acSnap) { showZDRInfo.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            if showZDRInfo {
                Text("ZDR (Zero Data Retention) tells OpenRouter to route your requests only to upstream providers contractually bound to not log or retain prompts and responses. This is AC's default for privacy. A handful of less common models are only available on non-ZDR providers — turn this off in that case.")
                    .font(.acCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Turn off Zero Data Retention?", isPresented: $showZDRDisableConfirm) {
            Button("Turn off", role: .destructive) {
                zdrEnabled = false
                OnlineProviderRouting.setZDREnforced(false)
            }
            Button("Keep on", role: .cancel) { }
        } message: {
            Text("Without ZDR, upstream providers chosen by OpenRouter may log your prompts and screenshots. AC's defaults work great with ZDR on — only disable this if you've picked an advanced model that isn't offered on a ZDR endpoint.")
        }
    }

    /// Compact "text · image" model summary shown under each tier in the BYOK picker.
    /// Keeps users honest about exactly which OpenRouter models a tier maps to.
    private func tierModelSummary(for tier: AITier) -> String {
        let text = AppController.shortModelName(for: tier.byokModelIdentifierText)
        let image = AppController.shortModelName(for: tier.byokModelIdentifierImage)
        return text == image ? "Models: \(text)" : "Models: \(text) · \(image)"
    }

    private var advancedModelsAreDirty: Bool {
        guard config.inferenceBackend == .openRouter else { return false }
        let trimmedText = advancedTextModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = advancedImageModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText != (config.onlineModelIdentifierText ?? config.onlineModelIdentifier)
            || trimmedImage != (config.onlineModelIdentifierImage ?? config.onlineModelIdentifier)
    }

    /// Seeds the OpenRouter advanced text/image fields from the current config.
    /// Local custom models use the inline adder, which keeps its own empty drafts.
    private func resetAdvancedModelDrafts() {
        if config.inferenceBackend == .openRouter {
            advancedTextModelID = config.onlineModelIdentifierText ?? config.onlineModelIdentifier
            advancedImageModelID = config.onlineModelIdentifierImage ?? config.onlineModelIdentifier
        } else {
            advancedLocalModelName = ""
            advancedTextModelID = ""
            advancedImageModelID = ""
        }
    }

    private func saveAdvancedModels() {
        guard config.inferenceBackend == .openRouter else { return }
        let trimmedText = advancedTextModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = advancedImageModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedImage.isEmpty else { return }
        controller.updateOnlineModelIdentifierText(trimmedText)
        controller.updateOnlineModelIdentifierImage(trimmedImage)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }
}

private struct LocalModelCardDescriptor: Identifiable {
    let title: String
    let subtitle: String
    let detail: String
    let modelIdentifier: String
    let tier: AITier?
    let isRecommended: Bool

    var id: String { modelIdentifier }
}
