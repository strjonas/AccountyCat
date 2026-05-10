//
//  LearnedToastView.swift
//  AC
//
//  Subtle "AC learned: …" toast surfaced when a memory entry or rule is auto-added
//  (i.e. not from a direct user statement). One-line, with a small Undo affordance.
//

import SwiftUI

struct LearnedToastView: View {
    let toast: LearnedToast
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @Environment(\.acAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("AC learned")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.06)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.acTextPrimary.opacity(0.5))
                Text(toast.detail)
                    .font(.ac(11, weight: .medium))
                    .foregroundStyle(Color.acTextPrimary.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 6)

            Button(action: onUndo) {
                Text("undo")
                    .font(.ac(10, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(accent.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help("Undo this learned change")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ACRadius.sm, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
        )
    }
}
