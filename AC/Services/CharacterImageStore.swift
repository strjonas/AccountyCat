//
//  CharacterImageStore.swift
//  AC
//
//  Offline storage + processing for custom-character portraits. Everything
//  stays on disk under the app's Application Support directory — nothing is
//  ever uploaded, which is the whole privacy/copyright story behind letting
//  users bring their own accountability partner.
//
//  Layout:  <AppSupport>/AC/characters/<characterID>/<expression>.png
//
//  Processing (all on-device): square-crop + downscale to 512, plus an
//  optional background removal pass (Vision) that also re-centres the subject.
//

import Foundation
import CoreImage
import Vision
import AppKit

struct CharacterImageStore: Sendable {
    /// Root that holds one subdirectory per custom character.
    let charactersRoot: URL

    /// Production store rooted at ~/Library/Application Support/AC/characters.
    init(fileManager: FileManager = .default) {
        self.charactersRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AC", isDirectory: true)
            .appendingPathComponent("characters", isDirectory: true)
    }

    /// Explicit-root initializer (tests use a temporary directory).
    init(charactersRoot: URL) {
        self.charactersRoot = charactersRoot
    }

    static func temporary() -> CharacterImageStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ac-test-characters-\(UUID().uuidString)", isDirectory: true)
        return CharacterImageStore(charactersRoot: url)
    }

    // MARK: - Paths

    func directory(for id: String) -> URL {
        charactersRoot.appendingPathComponent(id, isDirectory: true)
    }

    func imageURL(for id: String, expression: ACCatExpression) -> URL {
        directory(for: id).appendingPathComponent("\(expression.rawValue).png")
    }

    func hasImage(for id: String, expression: ACCatExpression) -> Bool {
        FileManager.default.fileExists(atPath: imageURL(for: id, expression: expression).path)
    }

    // MARK: - Write

    /// Process and store an image for one expression. Returns the directory the
    /// character's portraits live in (the value carried by `.files(directory:)`).
    @discardableResult
    func store(
        _ image: NSImage,
        for id: String,
        expression: ACCatExpression,
        removeBackground: Bool,
        crop: CGRect? = nil
    ) async throws -> URL {
        let data = try await CharacterImageProcessor.process(
            image,
            removeBackground: removeBackground,
            crop: crop
        )
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: imageURL(for: id, expression: expression), options: .atomic)
        return dir
    }

    /// Store already-processed PNG data verbatim (used when the caller has
    /// processed once and wants to persist without re-running Vision).
    @discardableResult
    func storeProcessedData(
        _ data: Data,
        for id: String,
        expression: ACCatExpression
    ) throws -> URL {
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: imageURL(for: id, expression: expression), options: .atomic)
        return dir
    }

    // MARK: - In-progress draft scratch

    // A reserved slot that holds the *unprocessed* images of a partner the user
    // is still creating, so closing the window mid-creation doesn't lose them.
    // Stored raw (not Vision-processed) so the crop/background choices can still
    // be re-applied on save. The leading underscore keeps it from ever colliding
    // with a real character id (those are UUIDs / built-in slugs).
    private static let draftID = "_draft"

    func draftImageURL(expression: ACCatExpression) -> URL {
        imageURL(for: Self.draftID, expression: expression)
    }

    func hasDraftImage(expression: ACCatExpression) -> Bool {
        hasImage(for: Self.draftID, expression: expression)
    }

    func loadDraftImage(expression: ACCatExpression) -> NSImage? {
        NSImage(contentsOf: draftImageURL(expression: expression))
    }

    /// Persist a picked image verbatim (PNG) into the draft scratch slot.
    func storeDraftImage(_ image: NSImage, expression: ACCatExpression) throws {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { throw CharacterImageProcessor.ProcessingError.encodeFailed }
        let dir = directory(for: Self.draftID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: draftImageURL(expression: expression), options: .atomic)
    }

    func removeDraftImage(expression: ACCatExpression) {
        try? FileManager.default.removeItem(at: draftImageURL(expression: expression))
    }

    func clearDraft() {
        removeAll(for: Self.draftID)
    }

    // MARK: - Delete

    func removeImage(for id: String, expression: ACCatExpression) {
        try? FileManager.default.removeItem(at: imageURL(for: id, expression: expression))
    }

    func removeAll(for id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}

// MARK: - Processing

enum CharacterImageProcessor {
    enum ProcessingError: Error {
        case invalidImage
        case renderFailed
        case encodeFailed
    }

    static let targetSize = 512

    /// Square-crop + downscale to 512×512 PNG.
    ///
    /// - `removeBackground` runs the Vision mask, which re-centres the subject
    ///   (manual `crop` is ignored in that case — the subject extent wins).
    /// - `crop` is a normalised rect (origin top-left, 0…1) describing the
    ///   square region the user framed in the creator. When absent, a centred
    ///   square is used.
    static func process(
        _ image: NSImage,
        removeBackground: Bool,
        crop: CGRect? = nil
    ) async throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProcessingError.invalidImage
        }

        var ciImage = CIImage(cgImage: cgImage)
        let squared: CIImage

        if removeBackground, let masked = try? foregroundMasked(cgImage: cgImage) {
            ciImage = masked
            squared = centerSquare(ciImage)
        } else if let crop {
            squared = croppedSquare(ciImage, normalized: crop)
        } else {
            squared = centerSquare(ciImage)
        }

        let scaled = scaleToTarget(squared)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let outRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        guard
            let output = context.createCGImage(
                scaled,
                from: outRect,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
        else {
            throw ProcessingError.renderFailed
        }
        guard let data = pngData(from: output) else {
            throw ProcessingError.encodeFailed
        }
        return data
    }

    // MARK: Background removal (Vision, on-device, macOS 14+)

    private static func foregroundMasked(cgImage: CGImage) throws -> CIImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { return nil }
        // Crop to the subject so it ends up centred in the square.
        let buffer = try result.generateMaskedImage(
            ofInstances: result.allInstances,
            from: handler,
            croppedToInstancesExtent: true
        )
        return CIImage(cvPixelBuffer: buffer)
    }

    // MARK: Geometry

    /// Center-crop to the largest square that fits, on a transparent canvas if
    /// the source isn't square.
    private static func centerSquare(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else {
            return image
        }
        let side = min(extent.width, extent.height)
        let originX = extent.midX - side / 2
        let originY = extent.midY - side / 2
        let cropRect = CGRect(x: originX, y: originY, width: side, height: side)
        // Translate so the crop sits at the origin.
        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
    }

    /// Crop to the user-framed square (normalised, top-left origin).
    ///
    /// The framed square can be *larger* than the image (the user zoomed out
    /// below 1× to add breathing room). In that case the crop rect extends past
    /// the image bounds, so we composite the subject onto a transparent square
    /// the full size of the framed region — the padding ends up invisible in the
    /// final PNG rather than the subject being stretched to fill.
    private static func croppedSquare(_ image: CIImage, normalized: CGRect) -> CIImage {
        let px = pixelRect(forNormalizedCrop: normalized, imageExtent: image.extent)
        guard px.width > 0, px.height > 0 else { return centerSquare(image) }
        let translated = image
            .cropped(to: px)
            .transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
        let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: px.width, height: px.height))
        return translated.composited(over: canvas)
    }

    /// Convert a normalised (top-left origin) crop rect into a pixel rect in
    /// CIImage space (bottom-left origin). Pure + testable.
    static func pixelRect(forNormalizedCrop n: CGRect, imageExtent e: CGRect) -> CGRect {
        let w = n.width * e.width
        let h = n.height * e.height
        let x = e.minX + n.minX * e.width
        // Flip Y: normalised y is distance from the top.
        let y = e.minY + (e.height - n.minY * e.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Map an interactive crop viewport (drag offset + zoom over an aspect-fill
    /// image in a square viewport) to a normalised crop rect (top-left origin).
    /// Pure + testable; the creator mirrors this same geometry on screen.
    static func normalizedCrop(
        zoom: CGFloat,
        offset: CGSize,
        viewport: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        let w = max(imageSize.width, 1)
        let h = max(imageSize.height, 1)
        let baseScale = viewport / min(w, h)        // aspect-fill at zoom 1
        let scale = baseScale * max(zoom, 0.0001)
        let displayedW = w * scale
        let displayedH = h * scale
        let originX = viewport / 2 - displayedW / 2 + offset.width
        let originY = viewport / 2 - displayedH / 2 + offset.height
        let cropSidePx = viewport / scale
        let cropXpx = (0 - originX) / scale
        let cropYpx = (0 - originY) / scale
        var nx = cropXpx / w
        var ny = cropYpx / h
        let nw = cropSidePx / w
        let nh = cropSidePx / h
        // When the framed square fits inside the image (zoom ≥ 1) clamp it so it
        // stays on-image. When it is larger (zoom < 1, downscaling) leave the
        // computed origin alone — it goes negative, which the processor turns
        // into transparent padding around the subject.
        if nw <= 1 { nx = min(max(nx, 0), 1 - nw) }
        if nh <= 1 { ny = min(max(ny, 0), 1 - nh) }
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    private static func scaleToTarget(_ image: CIImage) -> CIImage {
        let side = max(image.extent.width, 1)
        let scale = CGFloat(targetSize) / side
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: Encoding

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: targetSize, height: targetSize)
        return rep.representation(using: .png, properties: [:])
    }
}
