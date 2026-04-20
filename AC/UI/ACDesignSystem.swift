//
//  ACDesignSystem.swift
//  AC
//
//  Shared design tokens — palette, typography, animation curves, dimensions, and button styles.
//

import AppKit
import SwiftUI

// MARK: - Build Flags

enum ACBuild {
    /// True for Debug configuration builds; false for Release.
    /// Gate developer-only UI (test nudges, advanced pickers, telemetry browser) on this
    /// so the shipping build is a clean, minimal surface.
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

// MARK: - Color Palette

extension Color {
    // Warm neutrals
    static let acCream        = Color(red: 1.00, green: 0.97, blue: 0.93)
    static let acPaper        = Color(red: 0.99, green: 0.96, blue: 0.90)

    // Caramel accent
    static let acCaramel      = Color(red: 0.91, green: 0.66, blue: 0.35)
    static let acCaramelLight = Color(red: 0.97, green: 0.83, blue: 0.63)
    static let acCaramelSoft  = Color(red: 0.98, green: 0.90, blue: 0.75)

    // Blush & amber
    static let acBlush        = Color(red: 1.00, green: 0.74, blue: 0.78)
    static let acAmber        = Color(red: 0.98, green: 0.76, blue: 0.35)

    // Cat face
    static let acFur          = Color(red: 0.98, green: 0.85, blue: 0.60)
    static let acFurDark      = Color(red: 0.92, green: 0.70, blue: 0.43)
    static let acEyeColor     = Color(red: 0.28, green: 0.20, blue: 0.15)
    static let acNoseColor    = Color(red: 0.82, green: 0.43, blue: 0.43)
    static let acWhiskerColor = Color(red: 0.52, green: 0.36, blue: 0.24)

    // Text — adapts to light / dark mode
    static let acTextPrimary  = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.92, alpha: 1)   // near-white in dark mode
            : NSColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 1) // warm dark brown in light mode
    })
}

// MARK: - Typography

extension Font {
    /// Rounded system font — friendly and cohesive throughout the app.
    static func ac(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Animation

extension Animation {
    /// Responsive spring for interactions (expansions, mood changes).
    static let acSpring = Animation.spring(response: 0.44, dampingFraction: 0.68)
    /// Snappier spring for tab switches and small toggles.
    static let acSnap   = Animation.spring(response: 0.30, dampingFraction: 0.78)
    /// Smooth fade for opacity and colour transitions.
    static let acFade   = Animation.easeInOut(duration: 0.26)
}

// MARK: - Dimensions

enum ACD {
    static let orbDiameter: CGFloat  = 72
    static let panelWidth: CGFloat   = 200
    static let panelHeight: CGFloat  = 240   // room for bubble (with thumbs row) above orb
    static let popoverWidth: CGFloat = 472
}

// MARK: - Button Styles

/// Warm caramel primary action button.
struct ACPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(Color(red: 0.20, green: 0.12, blue: 0.05))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.acCaramelLight))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

/// Neutral secondary action button.
struct ACSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}
