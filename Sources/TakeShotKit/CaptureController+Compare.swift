import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Compare tooling: the pinned reference, punch-in, and the wipe/blend push.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Wipe position (0…1; left/top is playback).
    var wipePosition: Double {
        get { compareLive.wipePosition }
        set {
            guard newValue != compareLive.wipePosition else { return }
            compareLive.wipePosition = newValue
            pushCompare()
        }
    }
    /// Playback opacity in blend mode.
    var blendOpacity: Double {
        get { compareLive.blendOpacity }
        set {
            guard newValue != compareLive.blendOpacity else { return }
            compareLive.blendOpacity = newValue
            pushCompare()
        }
    }

    /// Live vs. playback compare mode.
    enum CompareMode: String, CaseIterable, Identifiable {
        case off        // playback only
        case wipe       // wipe
        case blend      // overlay with transparency
        case difference // per-pixel |A−B|, amplified by differenceGain
        case sideBySide // side by side
        var id: String { rawValue }
    }

    /// Difference-mode gain. A 2-code framing error is invisible at ×1, so the
    /// difference is amplified the way DaVinci and Nuke amplify theirs — and
    /// the steps are the values, not an index, so the compositor takes the raw
    /// value directly.
    enum DifferenceGain: Int, CaseIterable, Identifiable {
        case x1 = 1
        case x4 = 4
        case x16 = 16
        var id: Int { rawValue }
        /// The segment label. A multiplication sign and a number are symbols,
        /// not words — the same rule as the "%" beside the blend field.
        var label: String { "×\(rawValue)" }
    }

    /// Compare wipe direction.
    enum WipeOrientation: String, CaseIterable {
        case vertical    // vertical line, drags horizontally
        case horizontal  // horizontal line, drags vertically
        case diagonal    // 45°
    }

    /// What the A pane of the A/B split shows.
    enum ComparePaneSource: Equatable {
        case live
        case clip
    }

    /// Which picture belongs in the A pane. One property, read by the pane and
    /// asserted by the tests, because the wipe/blend composite and the split
    /// have to agree on what "the compare source" means — they disagreed, and
    /// A/B against another clip showed live on the left.
    var comparePaneSource: ComparePaneSource {
        compareClipURL == nil ? .live : .clip
    }

    /// Whether the viewer is showing the A|B split rather than one picture.
    ///
    /// Every surface that draws the player reads THIS — the main viewer, the
    /// fullscreen player and the external display. It is one property because
    /// the condition was written out once, in `PreviewView`, and the other two
    /// windows simply did not have it: with A/B engaged they drew the B side
    /// alone, so the operator's window showed two pictures and the director's
    /// monitor showed one. Wipe and blend are absent on purpose — those are
    /// composited into a single frame inside the tap (see `pushCompare`), and a
    /// split of an already-composited picture would show the compare clip twice.
    var showsCompareSplit: Bool {
        viewerMode == .playback && compareMode == .sideBySide
            && playbackURL != nil
    }

    /// Whether there is anything to compare the picture AGAINST right now.
    ///
    /// In playback the B side is the clip in the player (or another clip
    /// chosen beside it); in record it is the pinned reference and nothing
    /// else. Every compare CONTROL is meaningless without one — `pushCompare`
    /// sends `.off` to the pipeline while nothing is pinned, so a mode picker
    /// offered in that state is a control that changes nothing.
    var compareHasBSide: Bool {
        return viewerMode == .playback ? playbackURL != nil : referencePinned
    }

    /// Whether the compare on screen is BYPASSING the viewing LUT.
    ///
    /// Difference is a measurement, not a picture: both engines read the two
    /// halves at the pre-LUT stage and the |A−B| output never sees the cube,
    /// because a difference of two graded pictures is not the difference the
    /// operator is measuring. That is deliberate and pinned.
    ///
    /// What was NOT right is the indicator. The filter icon lit in the accent
    /// colour over a frame with no look on it, which reads as "the LUT is not
    /// working" — and is how the owner reported it ("в режиме дифф лут не
    /// применяется"). The pixels were correct; the icon was lying.
    ///
    /// It asks for the B side the way the RENDER does, not the way the bar
    /// does: with nothing to difference against, both engines fall through and
    /// apply the LUT after all, and saying "bypassed" there would be the same
    /// lie pointing the other way.
    var compareBypassesLook: Bool {
        guard compareMode == .difference else { return false }
        return viewerMode == .playback ? playbackURL != nil : referencePinned
    }

    /// Whether the compare row belongs over the player at all.
    ///
    /// One property rather than a condition written out in the chrome, for the
    /// reason `showsCompareSplit` and `showsWipeHandle` are properties: it is a
    /// decision about what the operator is OFFERED, and a test has to be able
    /// to ask it from a fresh install without rendering a window.
    ///
    /// **Why record mode asks `isCapturing` and not `referencePinned`.** It
    /// asked the latter, and that made live compare unreachable: the pin button
    /// is the only caller of `pinReferenceFromCurrentFrame()` in the app, it
    /// lives in this row, and the row only appeared once something was already
    /// pinned. The key was inside the lock — the same shape the taught REC
    /// indicator shipped with. The row is now offered whenever there is a frame
    /// to pin, and it collapses to the pin alone until there is a B side (see
    /// `CompareControls`).
    ///
    /// Not in sync-play: the bar drives the single player's composite, which is
    /// not on screen under the grid.
    var showsCompareBar: Bool {
        guard syncPlay == nil else { return false }
        // Record mode asks `referencePinned` again, and this time it is right.
        //
        // It used to ask it, which made live compare unreachable — the pin was
        // the row's only content and the row only appeared once something was
        // pinned. The key was inside the lock, so the rule became `isCapturing`
        // and the row stood open all day holding one button.
        //
        // The pin has since moved to PLAYBACK, where the frame worth pinning
        // is (owner: "она должна быть видна тогда когда я включил какой либо
        // записанный шот"). So in record the row has nothing to hold until
        // something IS pinned — and asking `isCapturing` left an empty plate
        // hanging under the mode switch all day, which is what it looked like
        // (owner: "что за пипися торчит под рек/плейбэк?"). There is no lock
        // to be inside now: the door is one mode away.
        return viewerMode == .playback ? playbackURL != nil : referencePinned
    }

    /// Whether the draggable wipe seam belongs on screen.
    ///
    /// The wipe arrives already composited in the picture, so the seam is
    /// visible on every surface that draws the player — but the HANDLE that
    /// moves it lived in `PreviewView` alone. On the fullscreen player and the
    /// external display the operator could see the seam and had no way to touch
    /// it, which reads as a broken control rather than as a missing one. Same
    /// shape as `showsCompareSplit`, and for the same reason: one decision, read
    /// by all three.
    ///
    /// In playback there has to be a clip; in record there has to be a pinned
    /// reference, or there is no B side and the seam divides a picture from
    /// itself — which is `compareHasBSide`, shared with the bar so the two
    /// cannot come to disagree about what a B side is.
    ///
    /// **And not over a comparison**, the same guard `showsCompareBar` carries
    /// and for the same reason: the wipe is composited by the single player's
    /// tap, which is parked underneath a sync-play grid, so the seam divides
    /// nothing that is on screen. `PreviewView` hid it by accident — the
    /// overlay sits inside the branch the grid replaces — while the fullscreen
    /// player and the external display mount it beside the picture and drew a
    /// draggable seam across four takes.
    var showsWipeHandle: Bool {
        syncPlay == nil && compareMode == .wipe && compareHasBSide
    }

    /// The aspect the wipe seam rides: the composite is letterboxed into a
    /// centered aspect-fit box, and a handle that used the whole surface would
    /// sit off the picture at the top and bottom of a 16:9 frame in a taller
    /// window.
    var compareAspect: CGFloat {
        let live = PreviewView.liveAspect(signalFormat)
        guard viewerMode == .playback else { return live }
        return playbackAspect ?? live
    }

    /// Hotkey punch-in: straight to 2x and back off. Reads the level the pinch
    /// gesture may have left on screen (see +Assist), so the key never toggles
    /// off a magnification it cannot see.
    func togglePunchIn() {
        let magnified = liveAssist.punchIn > 1
        setAssist {
            $0.setPunchIn(magnified ? 1 : 2)
            if magnified {
                $0.panX = 0
                $0.panY = 0
            }
        }
    }
    /// Pin the current frame (live preview or the paused player frame).
    func pinReferenceFromCurrentFrame() {
        if viewerMode == .playback {
            guard let buffer = playbackTap.currentBuffer() else {
                lastError = L("reference_pin_failed")
                return
            }
            pipeline.setPreviewReference(buffer: buffer)
        } else {
            pipeline.pinReferenceFromCurrentFrame()
        }
        referencePinned = true
        // pinning means "compare me": default to the wipe in rec mode
        if compareMode == .off { compareMode = .wipe }
        if viewerMode == .playback { viewerMode = .record }
        pushCompare()
        lastNotice = L("reference_pinned")
    }
    /// Pin a still/photo from the record folder.
    ///
    /// **The decode and the render are OFF the main actor**, which is what
    /// `CIBufferRender`'s own doc has always claimed of its callers and this
    /// one was not doing. A 4K PNG off the record volume is a file read, a
    /// decode, a `CIContext` and a `waitUntilCompleted` — and on the MainActor
    /// that is the whole UI frozen, REC button included, while the camera is
    /// live. The two callers this was measured against
    /// (`CaptureController+Stills`) already hop.
    func pinReference(imageURL: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                await self?.reportPinFailed()
                return
            }
            // raw code values, like every other surface in the app
            let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            guard let buffer = CIBufferRender.render(
                image, width: cg.width, height: cg.height, into: nil) else {
                await self?.reportPinFailed()
                return
            }
            let held = UncheckedSendable(buffer)
            await MainActor.run { [weak self] in
                self?.adoptPinnedReference(held.value)
            }
        }
    }

    /// The half of `pinReference` that touches app state, back on the actor.
    @MainActor
    func adoptPinnedReference(_ buffer: CVPixelBuffer) {
        pipeline.setPreviewReference(buffer: buffer)
        referencePinned = true
        if compareMode == .off { compareMode = .wipe }
        viewerMode = .record
        pushCompare()
        lastNotice = L("reference_pinned")
    }

    @MainActor
    func reportPinFailed() {
        lastError = L("reference_pin_failed")
    }
    func unpinReference() {
        pipeline.setPreviewReference(buffer: nil)
        referencePinned = false
        pushCompare()
    }
    /// The operator's orientation as the axis the compositor cuts on.
    ///
    /// Internal rather than private because the wipe HANDLE needs the same
    /// mapping: the line the operator drags has to sit on the seam the
    /// compositor draws, and two spellings of "diagonal" is how they would
    /// come to disagree (see `CompareWipeGeometry`).
    static func compareAxis(
        _ orientation: WipeOrientation) -> CompareCompositor.Axis {
        switch orientation {
        case .vertical: return .vertical
        case .horizontal: return .horizontal
        case .diagonal: return .diagonal
        }
    }

    /// The wipe/blend the operator has dialled in, as the compositor's mode.
    ///
    /// `.sideBySide` composites nothing: the A|B split is two surfaces, not one
    /// blended frame (see `showsCompareSplit`).
    private func compareComposite() -> CompareCompositor.Mode {
        switch compareMode {
        case .off, .sideBySide: return .off
        case .blend: return .blend(opacity: blendOpacity)
        case .wipe: return .wipe(axis: Self.compareAxis(wipeOrientation),
                                 position: wipePosition)
        case .difference:
            return .difference(gain: Double(differenceGain.rawValue))
        }
    }

    /// Wipe/blend are composited inside the playback render (SwiftUI masking of
    /// video layers drops the colorspace) — push the parameters to the tap,
    /// and to the pipeline when a reference is pinned for live compare.
    ///
    /// One mode, pushed to both. The mapping used to be written out twice, once
    /// per consumer, so the two could disagree about what a mode meant — which
    /// is the same class of bug `comparePaneSource` exists to prevent.
    func pushCompare() {
        let mode = compareComposite()
        playbackTap.setCompare(mode)
        pipeline.setPreviewCompare(referencePinned ? mode : .off)
    }

    /// The compare mode and the difference gain survive a relaunch, like the
    /// rest of the operator's choices. Stored as nil at the defaults — the
    /// same convention as every other added settings field, so old saved JSON
    /// keeps decoding — and guarded so a didSet that changed nothing does not
    /// re-encode the whole settings blob.
    func persistCompareSettings() {
        let mode = compareMode == .off ? nil : compareMode.rawValue
        let gain = differenceGain == .x1 ? nil : differenceGain.rawValue
        guard settings.review.compareMode != mode
            || settings.review.compareDifferenceGain != gain else { return }
        settings.review.compareMode = mode
        settings.review.compareDifferenceGain = gain
    }
}
