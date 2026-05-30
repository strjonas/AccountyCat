//
//  CharacterImageStoreTests.swift
//  ACTests
//
//  Offline portrait storage + custom-character CRUD. All writes go to a
//  temporary directory — never the real Application Support tree.
//

import Foundation
import AppKit
import Testing
@testable import AC

struct CharacterImageStoreTests {

    private func makeImage(_ size: CGFloat = 200, color: NSColor = .systemTeal) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    @Test
    func storesAndResolvesProcessedPortrait() async throws {
        let store = CharacterImageStore.temporary()
        let url = try await store.store(
            makeImage(), for: "abc", expression: .neutral, removeBackground: false
        )

        // The file exists and is a decodable, square 512 image.
        #expect(store.hasImage(for: "abc", expression: .neutral))
        let written = try Data(contentsOf: store.imageURL(for: "abc", expression: .neutral))
        let decoded = try #require(NSImage(data: written))
        let rep = try #require(NSBitmapImageRep(data: written))
        #expect(rep.pixelsWide == CharacterImageProcessor.targetSize)
        #expect(rep.pixelsHigh == CharacterImageProcessor.targetSize)
        #expect(decoded.isValid)
        #expect(url.lastPathComponent == "abc")

        store.removeAll(for: "abc")
        #expect(!store.hasImage(for: "abc", expression: .neutral))
    }

    @Test
    func missingPoseFallsBackToNeutral() async throws {
        let store = CharacterImageStore.temporary()
        try await store.store(makeImage(), for: "fallback", expression: .neutral, removeBackground: false)

        // Only neutral exists; asking for .happy resolves to the neutral image.
        let resolved = CatView.loadCustomImage(
            directory: store.directory(for: "fallback").path,
            expression: .happy
        )
        #expect(resolved != nil)
        store.removeAll(for: "fallback")
    }

    @MainActor
    @Test
    func deletingActiveCustomFallsBackToMochiAndClearsStorage() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        let custom = ACCharacter.custom(
            id: "to-delete",
            name: "Coach",
            description: "Encouraging.",
            directory: controller.characterImageStore.directory(for: "to-delete").path,
            accentSeed: ACColorSeed(0.4, 0.5, 0.6)
        )
        controller.upsertCustomCharacter(custom)
        controller.updateCharacter(custom)
        #expect(controller.state.characterID == "to-delete")
        #expect(controller.state.customCharacters.count == 1)

        controller.deleteCustomCharacter(id: "to-delete")
        #expect(controller.state.character.id == "mochi")
        #expect(controller.state.customCharacters.isEmpty)
    }

    // MARK: - Crop geometry (pure math)

    @Test
    func centeredSquareImageCropsToFullFrame() {
        let crop = CharacterImageProcessor.normalizedCrop(
            zoom: 1, offset: .zero, viewport: 240, imageSize: CGSize(width: 300, height: 300)
        )
        #expect(abs(crop.minX) < 0.001)
        #expect(abs(crop.minY) < 0.001)
        #expect(abs(crop.width - 1) < 0.001)
        #expect(abs(crop.height - 1) < 0.001)
    }

    @Test
    func portraitImageCentersSquareVertically() {
        // 200×300 portrait at zoom 1: full width, vertically centered band.
        let crop = CharacterImageProcessor.normalizedCrop(
            zoom: 1, offset: .zero, viewport: 240, imageSize: CGSize(width: 200, height: 300)
        )
        #expect(abs(crop.width - 1) < 0.01)
        #expect(abs(crop.height - (200.0 / 300.0)) < 0.01)
        #expect(abs(crop.minY - (1.0 / 6.0)) < 0.01) // centered: (1 - 2/3)/2
    }

    @Test
    func draggingDownRevealsTopOfPortrait() {
        // Dragging the image down (positive height) should move the crop toward
        // the top of the source — i.e. keep the head.
        let size = CGSize(width: 200, height: 300)
        let centered = CharacterImageProcessor.normalizedCrop(
            zoom: 1, offset: .zero, viewport: 240, imageSize: size
        )
        let draggedDown = CharacterImageProcessor.normalizedCrop(
            zoom: 1, offset: CGSize(width: 0, height: 60), viewport: 240, imageSize: size
        )
        #expect(draggedDown.minY < centered.minY)
        #expect(draggedDown.minY >= -0.0001) // clamped within image
    }

    @Test
    func zoomingOutPadsAroundTheSubject() {
        // Below 1× the framed square is larger than the image: the crop origin
        // goes negative and the size exceeds 1 (the extra becomes transparent
        // padding in the final PNG). Centered, since the editor pins the offset.
        let crop = CharacterImageProcessor.normalizedCrop(
            zoom: 0.5, offset: .zero, viewport: 240, imageSize: CGSize(width: 300, height: 300)
        )
        #expect(crop.width > 1)
        #expect(crop.minX < 0)
        #expect(abs(crop.minX - (1 - crop.width) / 2) < 0.001) // centered
    }

    @Test
    func zoomedOutOffsetRepositionsSubject() {
        // Below 1× the subject is smaller than the frame; the editor now lets the
        // user drag it around to position it (previously the offset was pinned to
        // zero). A horizontal nudge must move the framed window, not re-center it.
        let size = CGSize(width: 300, height: 300)
        let centered = CharacterImageProcessor.normalizedCrop(
            zoom: 0.5, offset: .zero, viewport: 240, imageSize: size
        )
        let nudged = CharacterImageProcessor.normalizedCrop(
            zoom: 0.5, offset: CGSize(width: 40, height: 0), viewport: 240, imageSize: size
        )
        #expect(nudged.width > 1)              // still padded around the subject
        #expect(nudged.minX < centered.minX)   // a positive drag shifts the window
    }

    @Test
    func downscaledCropStillProducesSquareTarget() async throws {
        let store = CharacterImageStore.temporary()
        let crop = CharacterImageProcessor.normalizedCrop(
            zoom: 0.5, offset: .zero, viewport: 240, imageSize: CGSize(width: 200, height: 200)
        )
        let data = try await CharacterImageProcessor.process(
            makeImage(200), removeBackground: false, crop: crop
        )
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == CharacterImageProcessor.targetSize)
        #expect(rep.pixelsHigh == CharacterImageProcessor.targetSize)
        _ = store
    }

    @Test
    func pixelRectFlipsYForCIImage() {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 200)
        // Top quarter of the image (top-left origin) → high Y in CIImage space.
        let top = CharacterImageProcessor.pixelRect(
            forNormalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 0.25), imageExtent: extent
        )
        #expect(abs(top.height - 50) < 0.001)
        #expect(abs(top.minY - 150) < 0.001) // 200 - 0 - 50
    }

    @MainActor
    @Test
    func upsertUpdatesExistingWithoutDuplicating() {
        let controller = AppController.makeForTesting(storageService: .temporary())
        var custom = ACCharacter.custom(
            id: "edit-me", name: "Mentor", description: "v1",
            directory: "/tmp/edit-me", accentSeed: ACColorSeed(0.5, 0.5, 0.5)
        )
        controller.upsertCustomCharacter(custom)
        controller.updateCharacter(custom)

        custom.userDescription = "v2"
        custom.displayName = "Mentor 2"
        controller.upsertCustomCharacter(custom)

        #expect(controller.state.customCharacters.count == 1)
        // Active resolved copy reflects the edit.
        #expect(controller.state.character.displayName == "Mentor 2")
        #expect(controller.state.character.userDescription == "v2")
    }
}
