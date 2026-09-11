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
        case difference // per-pixel |A−B|, at unity
        case sideBySide // side by side
        var id: String { rawValue }
    }

    /// Difference-mode gain. A 2-code framing error is invisible at ×1, so the
    /// difference is amplified the way DaVinci and Nuke amplify theirs — and
    /// the steps are the values, not an index, so the compositor takes the raw
    /// value directly.
    /// **How far the ladder has to reach, measured.**
    ///
    /// A framing check compares two setups that are supposed to match, so what
    /// it produces is a couple of code values. Measured through the compositor
    /// on two greys two codes apart (`CompareCompositorTests`), out of 255:
    /// ×1 reads 2, ×4 reads 6, ×16 reads 22. Twenty-two is nine per cent grey
    /// — dark enough that an operator looks at the control and asks what it is
    /// supposed to be doing (owner: "смысла в режиме diff на x4 и x16 я не
    /// понял вообще"). They were right: the top of the ladder did not reach
    /// the job.
    ///
    /// ×64 reads 89 on the same pair — a third of the way up the scale, and
    /// obvious on any monitor in any light. The lower steps stay because they are the ones
    /// that survive NOISE: a sensor's own floor is a code or two, so at the top
    /// step a clean pair of frames still glows grey, and the step that answers
    /// "is this a real difference or is it the noise" is a lower one.
    /// Compare wipe direction.
    enum WipeOrientation: String, CaseIterable {
        case vertical    // vertical line, drags horizontally
        case horizontal  // horizontal line, drags vertically
        case diagonal    // 45°, "/" — front on the top-left
        /// The other 45°, "\\" — front on the top-right (owner: "шторку
        /// диагональную хочу не только вправо но и влево"). Which one is
        /// wanted depends on where the thing being matched sits in the frame,
        /// and one of the two always cuts through it.
        case diagonalMirrored
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
        guard compareMode == .sideBySide, syncPlay == nil else { return false }
        // **Record mode gets it too, against the pinned reference.**
        //
        // It used to be playback-only, so choosing A/B with a reference pinned
        // did nothing at all: the picker offered the mode, the render asked
        // this, and this said no (owner: "а/б режим при пине рефа на странице
        // река не работает"). The other three modes composite the reference
        // INTO the live frame, so they needed no second surface — a split is
        // two pictures, and the reference had no way onto the screen except
        // through the compositor. It has one now (`PreviewMount.reference`).
        //
        // The condition is `compareHasBSide` in both modes rather than two
        // spellings of it: a split of a picture against nothing is a picture
        // beside a black rectangle.
        return compareHasBSide
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
    // MARK: - a reference that moves

    /// Whether the pinned reference is a CLIP rather than a still.
    var referenceIsMoving: Bool { referencePlayer != nil }

    /// Whether pinning right now would produce a moving reference.
    ///
    /// `playbackClipIsAVPlayerVideo` and NOT `transportBarKind`: that property
    /// opens by hiding itself for a clean feed, which is a statement about the
    /// CHROME and has nothing to say about what a pin can be — asking it here
    /// would freeze the reference for anyone working with the overlays off.
    var referenceCanPlay: Bool {
        isReviewingSingleClip && rawPlayer == nil
            && playbackClipIsAVPlayerVideo
            && settings.review.referencePlaysEffective
    }

    /// Whether the reference is ON SCREEN — the only reason to decode it.
    ///
    /// `.sideBySide` counts, and that is the trap: `compareComposite()` hands
    /// the pipeline `.off` for it because a split composites nothing, so a rule
    /// written against the pipeline's own mode would stop decoding exactly
    /// where the reference has a whole surface to itself.
    var referenceShouldDecode: Bool {
        referenceIsMoving && viewerMode == .record && compareMode != .off
    }

    /// Whether the freeze control belongs on the compare bar.
    var showsReferenceTransport: Bool { referenceIsMoving && showsCompareBar }

    /// Whether the reference clip is rolling right now — what the freeze
    /// control draws itself from.
    var referenceIsRolling: Bool { referencePlayer?.isPlaying ?? false }

    /// Start or stop the reference's decode to match what is on screen.
    ///
    /// Called from the three places that can change the answer: the viewer
    /// mode, the compare mode, and pinning or unpinning. A decode running for
    /// a reference nobody is looking at is the "decode for nothing" this app
    /// refuses everywhere else — and it would be running beside a camera.
    func applyReferenceRunning() {
        referencePlayer?.setRunning(referenceShouldDecode)
    }

    /// Freeze the reference where it is, or let it run again.
    func toggleReferencePlaying() {
        referencePlayer?.togglePlaying()
    }

    /// Build the reference clip for the take under review, if this pin can be
    /// one. The still is pinned either way: a player that has not produced its
    /// first frame yet falls back to it rather than to black.
    private func adoptReferenceClip() {
        referencePlayer?.shutDown()
        referencePlayer = nil
        pipeline.setReferenceFrameProvider(nil)
        guard referenceCanPlay, let url = playbackURL else { return }
        let player = ReferenceClipPlayer(
            url: url, range: transport.currentRange,
            startAt: transport.position.currentTime, pipeline: pipeline)
        referencePlayer = player
        pipeline.setReferenceFrameProvider { [weak player] in
            player?.latestFrame()
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
            // …and the clip behind that frame, when it is one. Built BEFORE
            // the mode switch below, which is what still knows which clip was
            // under review and where its playhead was.
            adoptReferenceClip()
        } else {
            pipeline.pinReferenceFromCurrentFrame()
        }
        referencePinned = true
        // pinning means "compare me": default to the wipe in rec mode
        if compareMode == .off { compareMode = .wipe }
        if viewerMode == .playback { viewerMode = .record }
        pushCompare()
        applyReferenceRunning()
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
        // The clip first: a provider left installed over a torn-down player
        // would hold that player's last frame for ever, which is a still
        // nobody pinned.
        referencePlayer?.shutDown()
        referencePlayer = nil
        pipeline.setReferenceFrameProvider(nil)
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
        case .diagonalMirrored: return .diagonalMirrored
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
            // **Unity, and no picker over it.**
            //
            // The gain was ×1/×4/×16/×64 in the compare bar, and the owner has
            // said twice that only the first is of any use ("кроме х1 смысла
            // не вижу в них"). A difference is a MEASUREMENT: three ways to
            // multiply it are three ways to leave the instrument reading
            // something other than what it measured, and the operator cannot
            // see from the picture which one is set. `compareDifferenceGain`
            // is tombstoned on the record — see `RetiredSettingTests`.
            return .difference(gain: 1)
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

    /// The compare mode survives a relaunch, like the rest of the operator's
    /// choices. Stored as nil at the default — the same convention as every
    /// other added settings field, so old saved JSON keeps decoding — and
    /// guarded so a didSet that changed nothing does not re-encode the whole
    /// settings blob.
    ///
    /// The difference GAIN used to be written here beside it. It is retired:
    /// the field stays on the record so a blob carrying it still decodes and a
    /// downgrade finds its value, and nothing reads or writes it
    /// (`RetiredSettingTests`).
    func persistCompareSettings() {
        let mode = compareMode == .off ? nil : compareMode.rawValue
        guard settings.review.compareMode != mode else { return }
        settings.review.compareMode = mode
    }
}
