import AVFoundation
import AppKit
import CaptureCore
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The plate that shows through the key: choosing one, decoding it, and where
/// it sits in the frame.
///
/// Its own file because it is a different job from keying. The plate can come
/// from anywhere the app already knows about — a take, an Other-content file, or
/// a file panel — and none of that has anything to do with the chroma math in
/// `+ChromaKey`.
extension CaptureController {
    // MARK: - where the plate sits

    /// The layout as the surfaces are showing it, mid-drag included.
    var chromaPlate: ChromaKey.PlateLayout { liveAssist.chroma.plate }

    /// Fit / fill / stretch. A click, so it publishes at once.
    var chromaPlateFit: ChromaKey.PlateFit {
        get { chromaPlate.fit }
        set { setAssist { $0.chroma.plate.fit = newValue } }
    }

    /// Magnification on top of the fit — dragged, so it goes through the draft.
    var chromaPlateScale: Double {
        get { chromaPlate.scale }
        set {
            applyAssistPreview {
                $0.chroma.plate.scale = min(ChromaKey.PlateLayout.maxScale,
                                            max(ChromaKey.PlateLayout.minScale,
                                                newValue))
            }
        }
    }

    var chromaPlateOffsetX: Double {
        get { chromaPlate.offsetX }
        set { setPlateOffset(x: newValue, y: chromaPlate.offsetY) }
    }

    var chromaPlateOffsetY: Double {
        get { chromaPlate.offsetY }
        set { setPlateOffset(x: chromaPlate.offsetX, y: newValue) }
    }

    private func setPlateOffset(x: Double, y: Double) {
        let limit = ChromaKey.PlateLayout.maxOffset
        applyAssistPreview {
            $0.chroma.plate.offsetX = min(limit, max(-limit, x))
            $0.chroma.plate.offsetY = min(limit, max(-limit, y))
        }
    }

    /// Back to a plain centered fit. Three sliders and a picker to put back by
    /// hand is exactly the kind of thing an operator does not do mid-take.
    func resetChromaPlate() {
        setAssist { $0.chroma.plate = .identity }
    }

    /// Whether the layout is anything other than the plain fit — what the reset
    /// button is enabled by.
    var chromaPlateIsAdjusted: Bool { chromaPlate != .identity }

    // MARK: - choosing one

    /// The app's own media, as the plate picker offers it: takes and Other
    /// content, kept apart, stills and clips both (a clip contributes a frame).
    var chromaPlateSources: [MediaSourceGroupItems] { mediaSources(.any) }

    /// Pick the intended background off disk. Stills AND clips: the plate is a
    /// picture either way, and a unit that has the plate as a QuickTime should
    /// not have to export a frame of it first.
    func chooseChromaBackgroundImage() {
        guard let url = FilePanel.openOne(.init(
            contentTypes: (Self.imageExtensions.union(Self.videoExtensions))
                .compactMap { UTType(filenameExtension: $0) },
            message: L("chroma_choose_image"))) else { return }
        loadChromaBackground(mediaURL: url)
    }

    /// Decode a plate and hand it to the display stage.
    ///
    /// The same path a pinned reference still takes (`pinReference(imageURL:)`):
    /// managed input rendered INTO Rec.709, so a plate that arrives with an
    /// sRGB or Display P3 profile is converted exactly once, here, rather than
    /// by whatever draws it later. Off the main actor — the art department's
    /// plate is a 6K TIFF as often as not, and a clip has to be opened and
    /// decoded before it yields one.
    func loadChromaBackground(mediaURL url: URL) {
        settings.chromaKeyBackgroundImagePath = url.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = await Self.decodePlate(url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let decoded else {
                    self.lastError = L("chroma_image_failed")
                    return
                }
                self.pipeline.setChromaBackgroundImage(decoded.value)
                self.chromaBackgroundImageName = url.lastPathComponent
            }
        }
    }

    /// The decode itself, off the actor. `nonisolated` and static so the
    /// detached task above does not have to reach back into the controller for
    /// anything but the answer.
    nonisolated private static func decodePlate(
        _ url: URL) async -> UncheckedSendable<CVPixelBuffer>? {
        let ext = url.pathExtension.lowercased()
        let cg = imageExtensions.contains(ext)
            ? stillImage(at: url) : await firstVideoFrame(at: url)
        guard let cg else { return nil }
        let attachments = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
            .takeRetainedValue() ?? CGColorSpaceCreateDeviceRGB()
        guard let buffer = CIBufferRender.render(CIImage(cgImage: cg),
                                                 width: cg.width,
                                                 height: cg.height,
                                                 into: space) else { return nil }
        return UncheckedSendable(buffer)
    }

    nonisolated private static func stillImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// The head frame of a clip, at full resolution.
    ///
    /// The head and not the middle, which is what the take THUMBNAILS use: a
    /// thumbnail is a poster and wants the most representative frame, while a
    /// plate is a backdrop the operator lines the actor up against and wants a
    /// frame they can predict. Zero tolerance either way, so "the first frame"
    /// is the first frame.
    nonisolated private static func firstVideoFrame(at url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }

    func clearChromaBackgroundImage() {
        pipeline.setChromaBackgroundImage(nil)
        chromaBackgroundImageName = nil
        settings.chromaKeyBackgroundImagePath = nil
    }

    // MARK: - persistence

    /// The layout stored alongside the rest of the key's dial-in, each field nil
    /// at its default so a blob this build writes still decodes on one that has
    /// never heard of a plate layout.
    static func storePlateLayout(_ layout: ChromaKey.PlateLayout,
                                 into settings: inout CaptureSettings) {
        let base = ChromaKey.PlateLayout.identity
        settings.chromaKeyPlateFit = layout.fit == base.fit
            ? nil : layout.fit.rawValue
        settings.chromaKeyPlateScale = layout.scale == base.scale
            ? nil : layout.scale
        settings.chromaKeyPlateOffsetX = layout.offsetX == base.offsetX
            ? nil : layout.offsetX
        settings.chromaKeyPlateOffsetY = layout.offsetY == base.offsetY
            ? nil : layout.offsetY
    }

    static func plateLayout(from stored: CaptureSettings) -> ChromaKey.PlateLayout {
        var layout = ChromaKey.PlateLayout()
        layout.fit = stored.chromaKeyPlateFit
            .flatMap(ChromaKey.PlateFit.init(rawValue:)) ?? layout.fit
        layout.scale = stored.chromaKeyPlateScale ?? layout.scale
        layout.offsetX = stored.chromaKeyPlateOffsetX ?? layout.offsetX
        layout.offsetY = stored.chromaKeyPlateOffsetY ?? layout.offsetY
        layout.clamp()
        return layout
    }
}
