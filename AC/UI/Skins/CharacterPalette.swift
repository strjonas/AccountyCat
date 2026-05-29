//
//  CharacterPalette.swift
//  AC
//
//  The full set of character-driven colors used across the UI (orb gradients,
//  accents, rings, header gradients, shadows). Previously these were ~15 giant
//  `switch self` blocks on the ACCharacter enum. Now:
//
//   • The three original cats keep their exact hand-tuned palettes (no visual
//     regression).
//   • New built-ins (dog, orb) and user-created characters derive a coherent
//     palette from a single accent seed via `CharacterPalette(seed:)`.
//
//  `ACCharacter` exposes `palette` plus passthrough accessors so every existing
//  call site (`character.accentColor`, `character.orbTopColor`, …) keeps
//  compiling unchanged.
//

import SwiftUI

struct CharacterPalette {
    // Orb gradient (resting + nudging)
    var orbTop: Color
    var orbBottom: Color
    var nudgingOrbTop: Color
    var nudgingOrbBottom: Color

    // Accent family — the primary character tint used everywhere
    var accent: Color
    var accentLight: Color
    var accentSoft: Color

    // Rings
    var ring: Color
    var escalatedRing: Color

    // Shadow
    var shadow: Color

    // Header gradient
    var headerLightTop: Color
    var headerLightBottom: Color
    var headerDarkTop: Color
    var headerDarkBottom: Color

    // Subtle personality-aware tint
    var personalityHue: Color
}

// MARK: - Hand-tuned built-in palettes (the original three cats)

extension CharacterPalette {
    static let mochi = CharacterPalette(
        orbTop: Color(red: 1.00, green: 0.96, blue: 0.89),
        orbBottom: Color(red: 0.98, green: 0.88, blue: 0.72),
        nudgingOrbTop: Color(red: 1.00, green: 0.95, blue: 0.78),
        nudgingOrbBottom: Color(red: 0.98, green: 0.82, blue: 0.52),
        accent: Color(red: 0.91, green: 0.66, blue: 0.35),
        accentLight: Color(red: 0.97, green: 0.83, blue: 0.63),
        accentSoft: Color(red: 0.98, green: 0.90, blue: 0.75),
        ring: Color(red: 0.98, green: 0.76, blue: 0.35),
        escalatedRing: Color(red: 0.97, green: 0.60, blue: 0.35),
        shadow: Color(red: 0.75, green: 0.60, blue: 0.40),
        headerLightTop: Color(red: 1.00, green: 0.97, blue: 0.93),
        headerLightBottom: Color(red: 0.99, green: 0.94, blue: 0.87),
        headerDarkTop: Color(red: 0.22, green: 0.18, blue: 0.13),
        headerDarkBottom: Color(red: 0.18, green: 0.14, blue: 0.09),
        personalityHue: Color(red: 0.94, green: 0.78, blue: 0.52)
    )

    static let misty = CharacterPalette(
        orbTop: Color(red: 0.96, green: 0.97, blue: 0.99),
        orbBottom: Color(red: 0.82, green: 0.87, blue: 0.92),
        nudgingOrbTop: Color(red: 0.88, green: 0.92, blue: 0.97),
        nudgingOrbBottom: Color(red: 0.58, green: 0.68, blue: 0.83),
        accent: Color(red: 0.48, green: 0.58, blue: 0.72),
        accentLight: Color(red: 0.76, green: 0.83, blue: 0.90),
        accentSoft: Color(red: 0.90, green: 0.93, blue: 0.96),
        ring: Color(red: 0.56, green: 0.66, blue: 0.80),
        escalatedRing: Color(red: 0.62, green: 0.50, blue: 0.78),
        shadow: Color(red: 0.40, green: 0.46, blue: 0.55),
        headerLightTop: Color(red: 0.96, green: 0.97, blue: 0.99),
        headerLightBottom: Color(red: 0.88, green: 0.92, blue: 0.96),
        headerDarkTop: Color(red: 0.13, green: 0.16, blue: 0.20),
        headerDarkBottom: Color(red: 0.09, green: 0.12, blue: 0.16),
        personalityHue: Color(red: 0.55, green: 0.65, blue: 0.78)
    )

    static let onyx = CharacterPalette(
        orbTop: Color(red: 0.99, green: 0.96, blue: 0.88),
        orbBottom: Color(red: 0.94, green: 0.83, blue: 0.58),
        nudgingOrbTop: Color(red: 0.98, green: 0.91, blue: 0.70),
        nudgingOrbBottom: Color(red: 0.85, green: 0.62, blue: 0.25),
        accent: Color(red: 0.80, green: 0.60, blue: 0.22),
        accentLight: Color(red: 0.94, green: 0.81, blue: 0.55),
        accentSoft: Color(red: 0.97, green: 0.91, blue: 0.78),
        ring: Color(red: 0.88, green: 0.66, blue: 0.28),
        escalatedRing: Color(red: 0.62, green: 0.30, blue: 0.45),
        shadow: Color(red: 0.45, green: 0.32, blue: 0.15),
        headerLightTop: Color(red: 0.99, green: 0.97, blue: 0.92),
        headerLightBottom: Color(red: 0.96, green: 0.90, blue: 0.78),
        headerDarkTop: Color(red: 0.16, green: 0.13, blue: 0.10),
        headerDarkBottom: Color(red: 0.11, green: 0.09, blue: 0.06),
        personalityHue: Color(red: 0.85, green: 0.66, blue: 0.30)
    )

    /// Map a built-in id to its hand-tuned palette, if it has one.
    static func handTuned(id: String) -> CharacterPalette? {
        switch id {
        case "mochi": return mochi
        case "misty": return misty
        case "onyx": return onyx
        default: return nil
        }
    }
}

// MARK: - Derived palette (dog, orb, and all custom characters)

extension CharacterPalette {
    /// Derive a complete, coherent palette from a single accent seed. Tuned to
    /// match the *relationships* in the hand-built cat palettes (light/soft
    /// tints, dark header stops, an urgency-shifted escalation ring) so derived
    /// characters feel like they belong in the same set.
    init(seed: ACColorSeed) {
        let base = RGB(seed)
        let white = RGB(1, 1, 1)
        let black = RGB(0, 0, 0)
        // Escalation pulls the hue toward a warm alert tone without abandoning
        // the character's identity.
        let alert = RGB(0.85, 0.34, 0.32)

        self.init(
            orbTop: base.mix(white, 0.90).color,
            orbBottom: base.mix(white, 0.66).color,
            nudgingOrbTop: base.mix(white, 0.74).color,
            nudgingOrbBottom: base.mix(white, 0.34).color,
            accent: base.color,
            accentLight: base.mix(white, 0.42).color,
            accentSoft: base.mix(white, 0.70).color,
            ring: base.mix(white, 0.18).color,
            escalatedRing: base.mix(alert, 0.45).color,
            shadow: base.mix(black, 0.45).color,
            headerLightTop: base.mix(white, 0.93).color,
            headerLightBottom: base.mix(white, 0.84).color,
            headerDarkTop: base.mix(black, 0.82).color,
            headerDarkBottom: base.mix(black, 0.88).color,
            personalityHue: base.mix(white, 0.26).color
        )
    }
}

// MARK: - Tiny RGB blend helper

private struct RGB {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ seed: ACColorSeed) {
        self.init(seed.red, seed.green, seed.blue)
    }

    /// Linear blend toward `other` by `t` (0 = self, 1 = other).
    func mix(_ other: RGB, _ t: Double) -> RGB {
        let c = min(max(t, 0), 1)
        return RGB(
            r + (other.r - r) * c,
            g + (other.g - g) * c,
            b + (other.b - b) * c
        )
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

// MARK: - ACColorSeed ↔ Color

extension ACColorSeed {
    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Best-effort conversion from a SwiftUI Color (via sRGB components).
    init(color: Color) {
        if let ns = NSColor(color).usingColorSpace(.sRGB) {
            self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        } else {
            self.init(0.55, 0.60, 0.82)
        }
    }
}

// MARK: - ACCharacter palette + passthroughs

extension ACCharacter {
    /// The resolved palette: hand-tuned for the original cats, derived from the
    /// accent seed for everything else (dog, orb, custom).
    var palette: CharacterPalette {
        if origin == .builtIn, let tuned = CharacterPalette.handTuned(id: id) {
            return tuned
        }
        return CharacterPalette(seed: accentSeed)
    }

    // Passthroughs — preserve every existing `character.<role>` call site.
    var orbTopColor: Color { palette.orbTop }
    var orbBottomColor: Color { palette.orbBottom }
    var nudgingOrbTopColor: Color { palette.nudgingOrbTop }
    var nudgingOrbBottomColor: Color { palette.nudgingOrbBottom }
    var accentColor: Color { palette.accent }
    var accentLight: Color { palette.accentLight }
    var accentSoft: Color { palette.accentSoft }
    var ringColor: Color { palette.ring }
    var escalatedRingColor: Color { palette.escalatedRing }
    var shadowColor: Color { palette.shadow }
    var headerLightTop: Color { palette.headerLightTop }
    var headerLightBottom: Color { palette.headerLightBottom }
    var headerDarkTop: Color { palette.headerDarkTop }
    var headerDarkBottom: Color { palette.headerDarkBottom }
    var personalityHue: Color { palette.personalityHue }
}
