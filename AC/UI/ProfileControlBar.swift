//
//  ProfileControlBar.swift
//  AC
//
//  Compact focus-profile control embedded in the popover header next to the
//  active model. It keeps profile state discoverable without consuming a full
//  row of the main popover.
//

import Combine
import SwiftUI

struct ProfileControlBar: View {
    private static let tickPublisher = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    @EnvironmentObject private var controller: AppController
    @Environment(\.colorScheme) private var colorScheme
    @State private var nowTick: Date = Date()
    @State private var isHovering: Bool = false
    @State private var isShowingPopover = false

    private var active: FocusProfile { controller.state.activeProfile }

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: active.isDefault ? "circle.fill" : "target")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(active.isDefault ? Color.secondary.opacity(0.95) : controller.state.character.accentColor)

                    Text(labelText)
                        .font(.ac(10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 68, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)

                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.45))
                    .frame(width: 1, height: 15)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.acTextPrimary.opacity(0.92))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(colorScheme == .dark
                                  ? controller.state.character.accentColor.opacity(0.74)
                                  : Color.white.opacity(0.80))
                    )
                    .padding(.leading, 4)
                    .padding(.trailing, 4)
            }
            .foregroundStyle(labelForeground)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(controlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(controlStroke, lineWidth: 1.05)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.50), lineWidth: 0.65)
                            .padding(1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(controller.state.character.accentColor.opacity(isHovering ? 0.85 : 0.55), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.24 : 0.17),
                    radius: isHovering ? 7 : 5,
                    x: 0,
                    y: isHovering ? 3 : 2)
            .scaleEffect(isHovering ? 1.01 : 1.0)
            .frame(minWidth: 102, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.acFade, value: isHovering)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            isHovering = hovering
        }
        .onReceive(Self.tickPublisher) { date in
            nowTick = date
        }
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            ProfileQuickPopoverView(showOpenAppButton: false)
                .environmentObject(controller)
                .acAccent(for: controller.state.character)
        }
        .help("Click to manage focus profile. \(helpText)")
    }

    private var controlFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.acSurface.opacity(active.isDefault ? 0.90 : 0.93),
                    controller.state.character.accentSoft.opacity(active.isDefault ? 0.25 : 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        return LinearGradient(
            colors: [
                Color.black.opacity(active.isDefault ? 0.10 : 0.12),
                controller.state.character.accentSoft.opacity(active.isDefault ? 0.26 : 0.34)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var controlStroke: Color {
        if active.isDefault {
            return colorScheme == .dark ? Color.white.opacity(0.34) : Color.acHairline.opacity(0.95)
        }
        return controller.state.character.accentColor.opacity(colorScheme == .dark ? 0.78 : 0.50)
    }

    private var labelForeground: Color {
        colorScheme == .dark ? Color.white.opacity(active.isDefault ? 0.88 : 0.96) : Color.acTextPrimary
    }

    private var labelText: String {
        if active.isDefault {
            return active.name
        }
        return "\(active.name)\(remainingText)"
    }

    private var remainingText: String {
        guard !active.isDefault, let exp = active.expiresAt else { return "" }
        let remaining = max(0, exp.timeIntervalSince(nowTick))
        let mins = Int(remaining / 60)
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m == 0 ? " · \(h)h" : " · \(h)h\(m)m"
        }
        return " · \(max(1, mins))m"
    }

    private var helpText: String {
        if active.isDefault {
            return "Active focus profile: \(active.name)"
        }
        return "Active focus profile: \(active.name)\(remainingText)"
    }
}
