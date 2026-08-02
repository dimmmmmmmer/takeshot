import AppKit
import CaptureCore
import CoreGraphics
import CoreImage
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The chroma-key preview's controller half: the controls the panel binds to,
/// the eyedropper, the plate that goes behind the actor, and what of all that
/// survives a relaunch.
///
/// The key itself rides inside `ViewAssist` (see the `chroma` member there), so
/// everything here goes through the same two doors the rest of the aids use —
/// `applyAssistPreview` for anything dragged, `setAssist` for anything clicked.
/// That is not tidiness: a write to `assist` per slider tick re-lays out the
/// whole window, which is the lag the LUT intensity slider had before the draft
/// state was introduced.
extension CaptureController {
    /// The key as the surfaces are showing it right now, mid-drag included.
    var chroma: ChromaKey { liveAssist.chroma }

    // MARK: - the toggle and the clicked controls

    var chromaKeyOn: Bool {
        get { liveAssist.chroma.isOn }
        set {
            setAssist { $0.chroma.isOn = newValue }
            // an armed eyedropper with the key switched off has nothing to pick
            // for; leaving the crosshair on the picture reads as a stuck mode
            if !newValue { chromaPickArmed = false }
        }
    }

    var chromaBackground: ChromaKey.Background {
        get { liveAssist.chroma.background }
        set { setAssist { $0.chroma.background = newValue } }
    }

    /// The screen color, as the swatch and the color well see it.
    var chromaKeyColor: Color {
        get { Color(chroma.keyColor) }
        set { setAssist { $0.chroma.keyColor = ChromaKey.RGB(newValue) } }
    }

    var chromaBackgroundColor: Color {
        get { Color(chroma.backgroundColor) }
        set { setAssist { $0.chroma.backgroundColor = ChromaKey.RGB(newValue) } }
    }

    /// The two presets. A click, not a drag — published straight away.
    func setChromaScreen(_ color: ChromaKey.RGB) {
        setAssist {
            $0.chroma.keyColor = color
            $0.chroma.isOn = true // picking a screen means "show me the key"
        }
    }

    // MARK: - the dragged controls

    /// Chroma distance that counts as screen (the similarity control).
    var chromaTolerance: Double {
        get { liveAssist.chroma.tolerance }
        set {
            applyAssistPreview {
                $0.chroma.tolerance = min(ChromaKey.maxTolerance, max(0, newValue))
            }
        }
    }

    /// Feather above the tolerance.
    var chromaSoftness: Double {
        get { liveAssist.chroma.softness }
        set {
            applyAssistPreview {
                $0.chroma.softness = min(ChromaKey.maxSoftness, max(0, newValue))
            }
        }
    }

    /// Spill suppression, 0…1.
    var chromaSpill: Double {
        get { liveAssist.chroma.spill }
        set {
            applyAssistPreview { $0.chroma.spill = min(1, max(0, newValue)) }
        }
    }

    // MARK: - the eyedropper

    /// Arm or disarm picking the screen color off the picture.
    ///
    /// Picking from the live image is the whole feature: nobody can name the
    /// green their cyc actually is under their actual lights, and every minute
    /// spent guessing at a color well is a minute the unit is waiting.
    func toggleChromaPick() {
        chromaPickArmed.toggle()
    }

    /// A click on the preview at `point`, on a `viewport`-sized surface (view
    /// coordinates, y down). Samples the displayed frame and adopts the color.
    ///
    /// The point goes through the same placement transform the renderer uses,
    /// so the pick lands on the pixel under the pointer through a desqueeze, a
    /// punch-in and a pan; a click on the letterbox is simply ignored.
    func pickChromaKeyColor(at point: CGPoint, viewport: CGSize) {
        guard let fraction = liveAssist.imageFraction(
            of: point, sourceSize: displaySourceSize(), in: viewport) else { return }
        guard let color = pipeline.sampleDisplayColor(atFractionX: Double(fraction.x),
                                                      y: Double(fraction.y)) else {
            lastError = L("chroma_pick_failed")
            return
        }
        chromaPickArmed = false
        setAssist {
            $0.chroma.keyColor = color
            $0.chroma.isOn = true
        }
        lastNotice = L("chroma_picked", color.hexString)
    }

    // MARK: - the plate

    /// Pick the intended background off disk.
    func chooseChromaBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.imageExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("chroma_choose_image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadChromaBackground(imageURL: url)
    }

    /// Decode a plate and hand it to the display stage.
    ///
    /// The same path a pinned reference still takes (`pinReference(imageURL:)`):
    /// managed input rendered INTO Rec.709, so a plate that arrives with an
    /// sRGB or Display P3 profile is converted exactly once, here, rather than
    /// by whatever draws it later. Off the main actor — the art department's
    /// plate is a 6K TIFF as often as not.
    func loadChromaBackground(imageURL url: URL) {
        settings.chromaKeyBackgroundImagePath = url.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = Self.decodePlate(url)
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
        _ url: URL) -> UncheckedSendable<CVPixelBuffer>? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
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

    func clearChromaBackgroundImage() {
        pipeline.setChromaBackgroundImage(nil)
        chromaBackgroundImageName = nil
        settings.chromaKeyBackgroundImagePath = nil
    }

    // MARK: - persistence

    /// The dial-in survives a relaunch; the switch does not (see
    /// `CaptureSettings.chromaKeyColorHex` for why). Everything is stored as
    /// nil at its default — the same convention as every other added field, so
    /// settings written by an older build still decode — and the whole blob is
    /// assigned once, because each write to `settings` runs the change handler.
    func persistChromaSettings() {
        let key = assist.chroma
        let base = ChromaKey()
        var updated = settings
        updated.chromaKeyColorHex = key.keyColor == base.keyColor
            ? nil : key.keyColor.hexString
        updated.chromaKeyTolerance = key.tolerance == base.tolerance
            ? nil : key.tolerance
        updated.chromaKeySoftness = key.softness == base.softness
            ? nil : key.softness
        updated.chromaKeySpill = key.spill == base.spill ? nil : key.spill
        updated.chromaKeyBackground = key.background == base.background
            ? nil : key.background.rawValue
        updated.chromaKeyBackgroundHex = key.backgroundColor == base.backgroundColor
            ? nil : key.backgroundColor.hexString
        guard updated != settings else { return }
        settings = updated
    }

    /// Restore the dial-in at launch — switched OFF, whatever it was left at.
    func restoreChroma(from stored: CaptureSettings) {
        var key = ChromaKey()
        if let hex = stored.chromaKeyColorHex,
           let color = ChromaKey.RGB(hex: hex) { key.keyColor = color }
        key.tolerance = stored.chromaKeyTolerance ?? key.tolerance
        key.softness = stored.chromaKeySoftness ?? key.softness
        key.spill = stored.chromaKeySpill ?? key.spill
        key.background = stored.chromaKeyBackground
            .flatMap(ChromaKey.Background.init(rawValue:)) ?? key.background
        if let hex = stored.chromaKeyBackgroundHex,
           let color = ChromaKey.RGB(hex: hex) { key.backgroundColor = color }
        key.clamp()
        key.isOn = false
        assist.chroma = key
        // the plate comes back with it; a file that has since been moved just
        // leaves the checkerboard showing
        if let path = stored.chromaKeyBackgroundImagePath,
           FileManager.default.fileExists(atPath: path) {
            loadChromaBackground(imageURL: URL(fileURLWithPath: path))
        }
    }
}

/// The bridge between the keyer's plain triple and SwiftUI's color type. Lives
/// here and not on the CaptureCore struct — that module has no SwiftUI.
extension Color {
    init(_ rgb: ChromaKey.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension ChromaKey.RGB {
    /// A picked color in the display's own code values. sRGB rather than the
    /// device space: the well hands back whatever the picker was showing, and
    /// the keyer measures the codes the signal arrives in.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent),
                  Double(ns.blueComponent))
    }
}
