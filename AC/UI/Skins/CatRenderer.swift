//
//  CatRenderer.swift
//  AC
//
//  Protocol for skin-specific cat renderers.
//

import SwiftUI

protocol CatRenderer {
    /// Render the cat into the given GraphicsContext.
    /// `size` is the bounding square; `expression` drives face shape.
    func render(
        in context: GraphicsContext,
        size: CGSize,
        character: ACCharacter,
        expression: ACCatExpression
    )
}
