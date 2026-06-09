//
//  CustomModelAddCard.swift
//  AC
//
//  Shared chrome for the "add a custom model" forms in the AI tab (local + online).
//

import SwiftUI

/// The collapsed/expanded chrome shared by the local and online "add a custom model"
/// affordances. Collapsed, it's a dashed "+ Add" button (or "Continue…" when a draft
/// is in progress); expanded, it shows a name field, caller-supplied source-specific
/// `fields`, an optional validation error, and the Clear / Add actions.
///
/// Collapsing (the chevron) never clears anything — the name/fields bindings live on
/// `AppController`, so an in-progress entry survives navigating away and back. Only
/// **Add** (on success) or the explicit **Clear** button wipes the draft.
///
/// This is the SwiftUI answer to "would I reuse one component in React?": one shared
/// container, two thin `fields` bodies. The bits that genuinely differ (HF/file source
/// pills vs. text/image model fields) stay with each caller; everything common lives here.
struct CustomModelAddCard<Fields: View>: View {
    @Binding var isExpanded: Bool
    @Binding var name: String
    var namePlaceholder: String
    /// Whether the draft has any content — drives the collapsed label and Clear button.
    var hasDraft: Bool
    var error: String?
    var isWorking: Bool
    var canAdd: Bool
    var addTitle: String
    var accent: Color
    var onAdd: () -> Void
    var onClear: () -> Void
    @ViewBuilder var fields: () -> Fields

    var body: some View {
        if isExpanded {
            expandedForm
        } else {
            collapsedButton
        }
    }

    private var collapsedButton: some View {
        Button {
            withAnimation(.acSnap) { isExpanded = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasDraft ? "square.and.pencil" : "plus.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(hasDraft ? "Continue adding model…" : "Add a custom model")
                    .font(.ac(11, weight: .medium))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                    .strokeBorder(accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }

    private var expandedForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Add a custom model")
                    .font(.ac(12, weight: .semibold))
                    .foregroundStyle(Color.acTextPrimary)
                Spacer()
                Button {
                    withAnimation(.acSnap) { isExpanded = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse — your entries are kept")
            }

            VStack(alignment: .leading, spacing: 5) {
                customModelFieldLabel("name")
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.ac(12))
                    .onSubmit(onAdd)
            }

            fields()

            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.ac(10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if hasDraft {
                    Button("Clear", action: onClear)
                        .buttonStyle(.plain)
                        .font(.ac(11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .disabled(isWorking)
                }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button(addTitle, action: onAdd)
                    .buttonStyle(ACPrimaryButton())
                    .disabled(!canAdd || isWorking)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(Color.acSurfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(Color.acHairline.opacity(0.7), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Caption-style label used above each field in the add forms. Free function so both
/// the shared card and the caller-supplied `fields` bodies render labels identically.
@ViewBuilder
func customModelFieldLabel(_ text: String) -> some View {
    Text(text)
        .font(.ac(11, weight: .semibold))
        .foregroundStyle(Color.acTextPrimary.opacity(0.7))
}
