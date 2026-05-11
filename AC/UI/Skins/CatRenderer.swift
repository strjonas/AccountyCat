//
//  CatRenderer.swift
//  AC
//
//  Protocol for skin-specific cat renderers.
//

import SwiftUI

protocol CatRenderer {
    /// Render the cat into the given GraphicsContext.
    /// `size` is the bounding square; `expression` drives face shape;
    /// `accent` is the user-selected accent color — renderers should use it
    /// for character-flavored elements (blush, charms, body tint) so the cat
    /// follows the user's chosen palette.
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression,
        accent: Color
    )
}
