import CaptureCore
import CoreGraphics
import Foundation
import SwiftUI

/// The chroma-key preview's controller half: the controls the panel binds to,
/// the eyedropper, and what of all that survives a relaunch. The plate that
/// goes behind the actor — loading it, and placing it — is `+ChromaPlate`.
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
            setAssist {
                $0.chroma.isOn = newValue
                // …and the bake goes with it. A bake left armed over no key is a
                // switch describing a take nobody can produce, and it would come
                // back armed the moment the key was switched on again — which is
                // the one state this feature must not be able to reach quietly.
                if !newValue { $0.chroma.record = false }
            }
            // an armed eyedropper with the key switched off has nothing to pick
            // for; leaving the crosshair on the picture reads as a stuck mode
            if !newValue { chromaPickArmed = false }
        }
    }

    /// Whether the bake switch is there to be reached at all.
    ///
    /// Stated as a rule and asserted as one, the way `canApplyLUT` is: there is
    /// nothing to bake without a key, and a switch offered over no key would
    /// write a stored flag claiming a composite that cannot happen. The way IN
    /// is the key's own toggle right above it — `chromaKeyOn = true` opens this
    /// gate and nothing else is required, which is what keeps the bake from
    /// living behind a condition only the bake could satisfy.
    var canBakeChromaKey: Bool { chromaKeyOn }

    /// Composite the key into the recording as well as onto the monitor.
    ///
    /// A click, not a drag, so it goes through `setAssist`. Turning the KEY off
    /// disarms it too (`chromaKeyOn`): a bake armed over no key would sit there
    /// claiming the next take is a composite when the pipeline would bake
    /// nothing, and the pipeline's own answer already reads both flags.
    var chromaRecordOn: Bool {
        get { liveAssist.chroma.record }
        set { setAssist { $0.chroma.record = newValue } }
    }

    var chromaBackground: ChromaKey.Background {
        get { liveAssist.chroma.background }
        set { setAssist { $0.chroma.background = newValue } }
    }

    /// The solid background, in the keyer's own triple.
    ///
    /// Not a SwiftUI `Color` (which is what the color well used to hand back):
    /// a round trip through `Color` and `NSColor` quantises to 8 bits per
    /// channel and moves a hex the operator typed by a code value.
    var chromaBackgroundRGB: ChromaKey.RGB {
        get { chroma.backgroundColor }
        set { setAssist { $0.chroma.backgroundColor = newValue.clamped() } }
    }

    /// The two presets. A click, not a drag — published straight away.
    func setChromaScreen(_ color: ChromaKey.RGB) {
        setAssist {
            $0.chroma.keyColor = color
            $0.chroma.isOn = true // picking a screen means "show me the key"
        }
    }

    // MARK: - the dragged controls

    /// Where the boundary between screen and subject sits, in chroma distance —
    /// the control that decides how much of the screen is keyed at all.
    var chromaTolerance: Double {
        get { liveAssist.chroma.tolerance }
        set {
            applyAssistPreview {
                $0.chroma.tolerance = min(ChromaKey.maxTolerance, max(0, newValue))
            }
        }
    }

    /// How gradually the matte crosses that boundary, 0…1 of the tolerance.
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
    ///
    /// Arming CLOSES the assist popover and remembers to bring it back. The
    /// pick is a click on the picture, i.e. a click outside the popover, and a
    /// popover that is open when it lands eats the click to dismiss itself — so
    /// the operator's first click did nothing and the second one picked a color
    /// with the panel already gone. Closing it deliberately makes the first
    /// click the pick, and reopening afterwards puts the operator back in front
    /// of the dials with the new key on screen, which is when the key is
    /// actually judged.
    func toggleChromaPick() {
        chromaPickArmed.toggle()
        if chromaPickArmed {
            // the taught REC indicator's box is waiting for a click on the same
            // pixels; two crosshairs is one mode too many (see
            // `toggleVisualRecTeach`) and the newer request wins
            visualRecTeachArmed = false
            chromaPickReopensAssist = showAssistPopover
            showAssistPopover = false
        } else {
            reopenAssistAfterPick()
        }
    }

    /// Put the popover back after a pick, if arming took it away.
    func reopenAssistAfterPick() {
        guard chromaPickReopensAssist else { return }
        chromaPickReopensAssist = false
        showAssistPopover = true
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
        // straight back to the dials, with the new key already on the picture
        reopenAssistAfterPick()
    }

    // MARK: - persistence

    /// The dial-in survives a relaunch; the switch does not (see
    /// `ChromaKeySettings.colorHex` for why). Everything is stored as
    /// nil at its default — the same convention as every other added field, so
    /// settings written by an older build still decode — and the whole blob is
    /// assigned once, because each write to `settings` runs the change handler.
    func persistChromaSettings() {
        let key = assist.chroma
        let base = ChromaKey()
        var updated = settings
        updated.chromaKey.colorHex = key.keyColor == base.keyColor
            ? nil : key.keyColor.hexString
        updated.chromaKey.tolerance = key.tolerance == base.tolerance
            ? nil : key.tolerance
        updated.chromaKey.softness = key.softness == base.softness
            ? nil : key.softness
        updated.chromaKey.spill = key.spill == base.spill ? nil : key.spill
        updated.chromaKey.background = key.background == base.background
            ? nil : key.background.rawValue
        updated.chromaKey.backgroundHex = key.backgroundColor == base.backgroundColor
            ? nil : key.backgroundColor.hexString
        Self.storePlateLayout(key.plate, into: &updated.chromaKey)
        guard updated != settings else { return }
        settings = updated
    }

    /// Restore the dial-in at launch — switched OFF, whatever it was left at,
    /// and the BAKE off with it: neither flag is in `ChromaKeySettings` at all,
    /// so `ChromaKey()`'s defaults are the whole of what comes back. See
    /// `ChromaKey.record` for why a stored bake would be the worst thing in this
    /// feature.
    func restoreChroma(from stored: ChromaKeySettings) {
        var key = ChromaKey()
        if let hex = stored.colorHex,
           let color = ChromaKey.RGB(hex: hex) { key.keyColor = color }
        key.tolerance = stored.tolerance ?? key.tolerance
        key.softness = stored.softness ?? key.softness
        key.spill = stored.spill ?? key.spill
        key.background = stored.background
            .flatMap(ChromaKey.Background.init(rawValue:)) ?? key.background
        if let hex = stored.backgroundHex,
           let color = ChromaKey.RGB(hex: hex) { key.backgroundColor = color }
        key.plate = Self.plateLayout(from: stored)
        key.clamp()
        key.isOn = false
        assist.chroma = key
        // the plate comes back with it; a file that has since been moved just
        // leaves the checkerboard showing
        if let path = stored.backgroundImagePath,
           FileManager.default.fileExists(atPath: path) {
            loadChromaBackground(mediaURL: URL(fileURLWithPath: path))
        }
    }
}

/// The bridge between the keyer's plain triple and SwiftUI's color type. Lives
/// here and not on the CaptureCore struct — that module has no SwiftUI.
///
/// One direction only, and deliberately: the swatches DRAW the key's colors,
/// and nothing hands one back any more. The reverse bridge went with the
/// `ColorPicker` that used to need it (owner item 30) — a round trip through
/// `NSColor` quantises to 8 bits a channel, so a typed hex came back a code
/// value away from itself.
extension Color {
    init(_ rgb: ChromaKey.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
