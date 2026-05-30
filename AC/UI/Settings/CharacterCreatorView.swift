//
//  CharacterCreatorView.swift
//  AC
//
//  Create or edit a custom "accountability partner" — your own image, a name,
//  and how they talk. Everything is processed and stored on-device
//  (CharacterImageStore); nothing is uploaded.
//
//  Fidelity ladder (progressive disclosure):
//    • Default — one image → a clean static portrait you can frame by dragging.
//    • "Animations" — opt-in procedural mood FX on the single image.
//    • "Add poses" — optional per-expression images for full expressiveness.
//

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

struct CharacterCreatorView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.dismiss) private var dismiss

    /// Existing character to edit, or nil to create a new one.
    var editing: ACCharacter?

    /// When embedded as a panel route (not a modal sheet) the view fills the
    /// panel width and reports closing through `onClose` instead of `dismiss`.
    var embeddedInPanel = false
    var onClose: (() -> Void)? = nil

    @State private var draft = Draft()
    @State private var neutralImage: NSImage?
    @State private var poseImages: [ACCatExpression: NSImage] = [:]
    @State private var selectedExpression: ACCatExpression = .neutral
    @State private var cropZooms: [ACCatExpression: CGFloat] = [:]
    @State private var cropOffsets: [ACCatExpression: CGSize] = [:]
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var didRestoreInitialState = false

    // Roughly the orb's real on-screen diameter (72pt), a touch larger so the
    // user sees how the portrait actually reads when small while still being
    // able to frame it.
    private let viewport: CGFloat = 120
    private let optionalPoses: [ACCatExpression] = [.happy, .concerned, .sleep, .blink]
    private var editableExpressions: [ACCatExpression] { [.neutral] + optionalPoses }

    /// Hard cap on the free-text description. Generous enough that nobody bumps
    /// it in normal use, but bounded because this text rides along in *every*
    /// chat and monitoring prompt — unbounded text would quietly burn tokens.
    private let maxDescription = 600

    private var accent: Color { draft.accent }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    titleBlock
                    cropHero
                    nameField
                    descriptionField
                    feelRow
                    animationsSection
                    if let errorText {
                        Text(errorText).font(.acCaption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            footer
        }
        .frame(width: embeddedInPanel ? nil : 420, height: embeddedInPanel ? nil : 640)
        .background(embeddedInPanel ? Color.clear : Color.acSurface)
        .onAppear(perform: restoreOnAppear)
        .onChange(of: draftSignature) { persistDraft() }
    }

    /// Close the creator — through the panel-route callback when embedded,
    /// otherwise by dismissing the sheet.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(editing == nil ? "Create your partner" : "Edit partner")
                .font(.ac(18, weight: .semibold))
                .foregroundStyle(Color.acTextPrimary)
            Text("Who keeps you accountable — and how they talk.")
                .font(.acCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Crop hero

    private var cropHero: some View {
        VStack(spacing: 12) {
            poseSelector
            CropEditor(
                image: image(for: selectedExpression),
                zoom: zoomBinding(for: selectedExpression),
                offset: offsetBinding(for: selectedExpression),
                viewport: viewport,
                accent: accent,
                onPick: { pickImage(for: selectedExpression) },
                onDropImage: { setImage($0, for: selectedExpression) }
            )
            if image(for: selectedExpression) != nil {
                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                    // Below 1× shrinks the portrait and pads it with transparency
                    // — handy when the subject shouldn't fill the whole circle.
                    Slider(value: zoomBinding(for: selectedExpression), in: 0.5...3)
                        .frame(width: 150)
                        .disabled(draft.removeBackground)
                        .opacity(draft.removeBackground ? 0.4 : 1)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                    Button("Change") { pickImage(for: selectedExpression) }
                        .buttonStyle(.plain)
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(accent)
                    if selectedExpression != .neutral {
                        Button("Remove") { removePose(selectedExpression) }
                            .buttonStyle(.plain)
                            .font(.ac(11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.85))
                            .help("Remove this pose — AC will use the main portrait")
                    }
                }

                // Background removal lives right under the image so it's the
                // first thing reachable when a photo arrives with a background.
                Toggle(isOn: $draft.removeBackground) {
                    Text("Remove background")
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(Color.acTextPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(accent)
                .fixedSize()

                Text(draft.removeBackground
                    ? "On-device — AC will isolate the subject for you."
                    : selectedExpression == .neutral
                        ? "drag to reframe — keep the face in the circle"
                        : "optional pose — skip it and AC uses the main portrait")
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private var poseSelector: some View {
        HStack(spacing: 8) {
            ForEach(editableExpressions, id: \.self) { expression in
                poseChip(expression)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func poseChip(_ expression: ACCatExpression) -> some View {
        let isSelected = selectedExpression == expression
        let image = image(for: expression)
        return Button {
            withAnimation(.acSnap) {
                selectedExpression = expression
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(Color.acSurfaceInset)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: expression == .neutral ? "photo" : "plus")
                            .font(.system(size: expression == .neutral ? 10 : 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke(isSelected ? accent.opacity(0.75) : Color.acHairline, lineWidth: isSelected ? 1.5 : 1)
                )
                Text(expression == .neutral ? "main" : expression.displayName)
                    .font(.ac(8, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? accent : .secondary)
            }
            .frame(width: 48)
        }
        .buttonStyle(.plain)
        .help(expression == .neutral ? "Main portrait" : "\(expression.displayName) pose")
    }

    // MARK: - Name

    private var nameField: some View {
        TextField("", text: $draft.name, prompt: Text("Name — e.g. Coach, Future You, Grandma").foregroundStyle(.secondary))
            .textFieldStyle(.plain)
            .font(.ac(17, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.acHairline).frame(height: 1)
            }
    }

    // MARK: - Description

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("How they talk")
                Spacer()
                Text("\(draft.description.count)/\(maxDescription)")
                    .font(.ac(9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(draft.description.count > maxDescription - 60
                        ? Color.orange
                        : Color.acTextPrimary.opacity(0.35))
            }
            ZStack(alignment: .topLeading) {
                if draft.description.isEmpty {
                    Text("e.g. My older, wiser self. Calm and patient, drops the occasional bit of hard-earned wisdom — never preachy.")
                        .font(.ac(12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.description)
                    .font(.ac(12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 76)
                    .padding(6)
                    .onChange(of: draft.description) { _, new in
                        if new.count > maxDescription {
                            draft.description = String(new.prefix(maxDescription))
                        }
                    }
            }
            .background(RoundedRectangle(cornerRadius: ACRadius.sm).fill(Color.acSurfaceInset))
            .overlay(RoundedRectangle(cornerRadius: ACRadius.sm).stroke(Color.acHairline, lineWidth: 1))
            Text("Shapes how AC *sounds* — never what it does.")
                .font(.ac(10))
                .foregroundStyle(.secondary)
            Text("Tip: a line or two is plenty. You can show how they'd react — e.g. \u{201C}if I slack off, say: hey, back to it.\u{201D} Optional, but it helps.")
                .font(.ac(10))
                .foregroundStyle(Color.acTextPrimary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Feel row (tone · expressiveness · accent)

    private var feelRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                segmented(title: "Tone", options: ACCharacterTone.allCases, selection: $draft.tone, fill: true) { toneLabel($0) }
                Text(toneHint(draft.tone))
                    .font(.ac(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 16) {
                segmented(title: "Voice", options: ACExpressiveness.allCases, selection: $draft.expressiveness, fill: true) { expressivenessLabel($0) }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Accent")
                    ColorPicker("", selection: $draft.accent, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28, height: 22)
                }
            }
            Text(expressivenessHint(draft.expressiveness))
                .font(.ac(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toneHint(_ tone: ACCharacterTone) -> String {
        switch tone {
        case .warm: return "Tone — the register they speak in. Warm: encouraging, friendly, in your corner."
        case .thoughtful: return "Tone — the register they speak in. Calm: measured, attentive, unhurried."
        case .sharp: return "Tone — the register they speak in. Sharp: direct, dry, cuts to it."
        }
    }

    // MARK: - Animations

    private var animationsSection: some View {
        Toggle(isOn: $draft.animationsEnabled) {
            labeledRow("Animations", "Gentle mood cues on your single image — a sway, a sleepy dim, drifting z's.")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Button("Cancel") {
                    if editing == nil { clearDraft() }
                    close()
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(isSaving ? "Saving…" : (editing == nil ? "Create partner" : "Save changes"))
                            .font(.ac(13, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(canSave ? accent : Color.gray.opacity(0.35)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Small builders

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.06)
            .foregroundStyle(Color.acTextPrimary.opacity(0.45))
            .textCase(.uppercase)
    }

    private func labeledRow(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.ac(12, weight: .medium)).foregroundStyle(Color.acTextPrimary)
            Text(hint).font(.ac(10)).foregroundStyle(.secondary)
        }
    }

    private func segmented<T: Hashable>(
        title: String,
        options: [T],
        selection: Binding<T>,
        fill: Bool = false,
        label: @escaping (T) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title)
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    let isSelected = selection.wrappedValue == option
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(label(option))
                            .font(.ac(10, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.white : Color.acTextPrimary.opacity(0.7))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .frame(maxWidth: fill ? .infinity : nil)
                            .background(Capsule().fill(isSelected ? accent : Color.acSurfaceInset))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: fill ? .infinity : nil)
        }
    }

    private func toneLabel(_ tone: ACCharacterTone) -> String {
        switch tone {
        case .warm: return "warm"
        case .thoughtful: return "calm"
        case .sharp: return "sharp"
        }
    }

    private func expressivenessLabel(_ e: ACExpressiveness) -> String {
        switch e {
        case .balanced: return "balanced"
        case .vivid: return "vivid"
        }
    }

    private func expressivenessHint(_ e: ACExpressiveness) -> String {
        switch e {
        case .balanced: return "Balanced — compact replies, but their voice clearly shows. Good default."
        case .vivid: return "Vivid — they take the wheel. Full personality, even in small talk."
        }
    }

    // MARK: - Validation

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && neutralImage != nil
    }

    private func image(for expression: ACCatExpression) -> NSImage? {
        expression == .neutral ? neutralImage : poseImages[expression]
    }

    private func zoom(for expression: ACCatExpression) -> CGFloat {
        cropZooms[expression] ?? 1
    }

    private func offset(for expression: ACCatExpression) -> CGSize {
        cropOffsets[expression] ?? .zero
    }

    private func zoomBinding(for expression: ACCatExpression) -> Binding<CGFloat> {
        Binding(
            get: { zoom(for: expression) },
            set: { cropZooms[expression] = $0 }
        )
    }

    private func offsetBinding(for expression: ACCatExpression) -> Binding<CGSize> {
        Binding(
            get: { offset(for: expression) },
            set: { cropOffsets[expression] = $0 }
        )
    }

    private func normalizedCrop(for expression: ACCatExpression, image: NSImage) -> CGRect {
        CharacterImageProcessor.normalizedCrop(
            zoom: zoom(for: expression),
            offset: offset(for: expression),
            viewport: viewport,
            imageSize: image.size
        )
    }

    // MARK: - Image picking

    private func pickImage(for expression: ACCatExpression) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        controller.suppressPopoverAutoClose?(true)
        defer { controller.suppressPopoverAutoClose?(false) }
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
            return
        }
        setImage(image, for: expression)
    }

    /// Drop an optional pose. The main portrait can never be removed (it's the
    /// required image). For a new partner the raw draft file is cleared right
    /// away; for an edit the on-disk PNG is deleted at save time so a cancel
    /// leaves the saved pose intact.
    private func removePose(_ expression: ACCatExpression) {
        guard expression != .neutral else { return }
        poseImages[expression] = nil
        cropZooms[expression] = nil
        cropOffsets[expression] = nil
        if editing == nil {
            controller.characterImageStore.removeDraftImage(expression: expression)
            persistDraft()
        }
        withAnimation(.acSnap) { selectedExpression = .neutral }
    }

    private func setImage(_ image: NSImage, for expression: ACCatExpression) {
        errorText = nil
        if expression == .neutral {
            neutralImage = image
            if !draft.accentTouched, let avg = image.averageColor {
                draft.accent = avg
                draft.accentTouched = false // keep auto-seeding until user edits
            }
        } else {
            poseImages[expression] = image
        }
        cropZooms[expression] = 1
        cropOffsets[expression] = .zero
        selectedExpression = expression
        // Persist the raw pick immediately so a mid-creation window close (e.g.
        // the user tabs away to grab an image) never loses it.
        if editing == nil {
            try? controller.characterImageStore.storeDraftImage(image, expression: expression)
            persistDraft()
        }
    }

    // MARK: - Load / restore

    /// On open: an existing character loads its saved state; a brand-new one
    /// rehydrates any in-progress draft left behind by a previous session.
    private func restoreOnAppear() {
        guard !didRestoreInitialState else { return }
        didRestoreInitialState = true
        if editing != nil {
            loadEditingCharacter()
        } else {
            restoreDraft()
        }
    }

    private func loadEditingCharacter() {
        guard let editing else { return }
        neutralImage = nil
        poseImages = [:]
        cropZooms = [:]
        cropOffsets = [:]
        draft.id = editing.id
        draft.name = editing.displayName
        draft.description = editing.userDescription ?? ""
        draft.tone = editing.tone
        draft.expressiveness = editing.expressiveness
        draft.accent = editing.accentSeed.color
        draft.accentTouched = true
        draft.animationsEnabled = editing.animationsEnabled
        let store = controller.characterImageStore
        if store.hasImage(for: editing.id, expression: .neutral) {
            neutralImage = NSImage(contentsOf: store.imageURL(for: editing.id, expression: .neutral))
        }
        for pose in optionalPoses where store.hasImage(for: editing.id, expression: pose) {
            poseImages[pose] = NSImage(contentsOf: store.imageURL(for: editing.id, expression: pose))
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave, let neutral = neutralImage else { return }
        isSaving = true
        errorText = nil
        let store = controller.characterImageStore
        let id = draft.id
        let removeBG = draft.removeBackground
        let poses = poseImages
        let optional = optionalPoses
        // Normalised crops the user framed (skipped when removing the background,
        // since the subject-mask re-centres on its own).
        let neutralCrop = removeBG ? nil : normalizedCrop(for: .neutral, image: neutral)
        let character = ACCharacter.custom(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: store.directory(for: id).path,
            accentSeed: ACColorSeed(color: draft.accent),
            tone: draft.tone,
            expressiveness: draft.expressiveness,
            animationsEnabled: draft.animationsEnabled
        )

        Task {
            do {
                try await store.store(neutral, for: id, expression: .neutral, removeBackground: removeBG, crop: neutralCrop)
                for (expr, image) in poses {
                    let poseCrop = removeBG ? nil : normalizedCrop(for: expr, image: image)
                    try await store.store(image, for: id, expression: expr, removeBackground: removeBG, crop: poseCrop)
                }
                // Delete any optional pose the user cleared (was saved before, now
                // absent). Without this the stale PNG lingers on disk and the pose
                // keeps showing instead of falling back to the main portrait.
                for expr in optional where poses[expr] == nil {
                    store.removeImage(for: id, expression: expr)
                }
                await MainActor.run {
                    controller.upsertCustomCharacter(character)
                    controller.updateCharacter(character)
                    clearDraft()
                    isSaving = false
                    close()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorText = "Couldn't save the image. Try a different one."
                }
            }
        }
    }

    // MARK: - Draft autosave (new partners only)

    private static let draftDefaultsKey = "ac.characterCreatorDraft"

    /// A cheap value that changes whenever any persistable field does, so a
    /// single `.onChange` can drive the autosave.
    private var draftSignature: String {
        let seed = ACColorSeed(color: draft.accent)
        return [
            draft.id, draft.name, draft.description,
            draft.tone.rawValue, draft.expressiveness.rawValue,
            "\(seed.red),\(seed.green),\(seed.blue)",
            "\(draft.accentTouched)", "\(draft.removeBackground)", "\(draft.animationsEnabled)",
            "\(zoom(for: .neutral))", "\(offset(for: .neutral).width),\(offset(for: .neutral).height)",
        ].joined(separator: "|")
    }

    private func persistDraft() {
        guard editing == nil else { return }
        let seed = ACColorSeed(color: draft.accent)
        let snapshot = PersistedDraft(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            tone: draft.tone,
            expressiveness: draft.expressiveness,
            accent: seed,
            accentTouched: draft.accentTouched,
            removeBackground: draft.removeBackground,
            animationsEnabled: draft.animationsEnabled,
            cropZoom: zoom(for: .neutral),
            cropOffsetW: offset(for: .neutral).width,
            cropOffsetH: offset(for: .neutral).height
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.draftDefaultsKey)
        }
    }

    private func restoreDraft() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.draftDefaultsKey),
            let snapshot = try? JSONDecoder().decode(PersistedDraft.self, from: data)
        else { return }
        draft.id = snapshot.id
        draft.name = snapshot.name
        draft.description = snapshot.description
        draft.tone = snapshot.tone
        draft.expressiveness = snapshot.expressiveness
        draft.accent = snapshot.accent.color
        draft.accentTouched = snapshot.accentTouched
        draft.removeBackground = snapshot.removeBackground
        draft.animationsEnabled = snapshot.animationsEnabled
        cropZooms[.neutral] = snapshot.cropZoom
        cropOffsets[.neutral] = CGSize(width: snapshot.cropOffsetW, height: snapshot.cropOffsetH)

        let store = controller.characterImageStore
        if store.hasDraftImage(expression: .neutral) {
            neutralImage = store.loadDraftImage(expression: .neutral)
        }
        for pose in optionalPoses where store.hasDraftImage(expression: pose) {
            poseImages[pose] = store.loadDraftImage(expression: pose)
        }
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: Self.draftDefaultsKey)
        controller.characterImageStore.clearDraft()
    }

    private struct PersistedDraft: Codable {
        var id: String
        var name: String
        var description: String
        var tone: ACCharacterTone
        var expressiveness: ACExpressiveness
        var accent: ACColorSeed
        var accentTouched: Bool
        var removeBackground: Bool
        var animationsEnabled: Bool
        var cropZoom: CGFloat
        var cropOffsetW: CGFloat
        var cropOffsetH: CGFloat
    }

    // MARK: - Draft

    struct Draft {
        var id: String = UUID().uuidString
        var name: String = ""
        var description: String = ""
        var tone: ACCharacterTone = .warm
        var expressiveness: ACExpressiveness = .balanced
        var accent: Color = ACColorSeed(0.55, 0.60, 0.82).color {
            didSet { accentTouched = true }
        }
        var accentTouched: Bool = false
        var removeBackground: Bool = false
        var animationsEnabled: Bool = false
    }
}

// MARK: - Interactive crop editor

private struct CropEditor: View {
    let image: NSImage?
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize
    let viewport: CGFloat
    let accent: Color
    var onPick: () -> Void
    var onDropImage: (NSImage) -> Void

    @State private var dragStart: CGSize?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: viewport, height: viewport)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .frame(width: viewport, height: viewport)
                    .clipShape(Circle())
                    .gesture(dragGesture)
            } else {
                Button(action: onPick) {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 26)).foregroundStyle(accent.opacity(0.8))
                        Text("drop a photo\nor click to choose")
                            .font(.ac(11)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .frame(width: viewport, height: viewport)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: viewport, height: viewport)
        .background(Circle().fill(Color.acSurfaceInset))
        .overlay(
            Circle().strokeBorder(
                style: StrokeStyle(lineWidth: 1.5, dash: image == nil ? [5, 4] : [])
            )
            .foregroundStyle(image == nil ? Color.acTextPrimary.opacity(0.3) : accent.opacity(0.5))
        )
        .overlay(alignment: .topTrailing) {
            if image != nil {
                Button(action: onPick) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.acSurface))
                        .overlay(Circle().stroke(Color.acHairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Choose a different image")
                .offset(x: 2, y: -2)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            loadDrop(providers)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? offset
                if dragStart == nil { dragStart = offset }
                offset = clampedOffset(CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                ))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Bound the drag so the subject stays usefully framed. Two regimes:
    ///   • zoomed in (displayed ≥ viewport): clamp so the image keeps covering
    ///     the circle — no transparent gap creeps in.
    ///   • zoomed out (displayed < viewport): the subject is smaller than the
    ///     frame, so let the user slide it anywhere within the circle to position
    ///     it. `abs(...)` gives a positive range in both regimes; the processor
    ///     turns the resulting padding into transparency on save.
    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let w = image.size.width, h = image.size.height
        let baseScale = viewport / min(w, h)
        let scale = baseScale * zoom
        let maxX = abs(w * scale - viewport) / 2
        let maxY = abs(h * scale - viewport) / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func loadDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { onDropImage(image) }
        }
        return true
    }
}

// MARK: - Average color (default accent seed)

extension NSImage {
    /// Coarse average color, used to suggest an accent from the chosen image.
    var averageColor: Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard extent.width > 0 else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return Color(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
    }
}
