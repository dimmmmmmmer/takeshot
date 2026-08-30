import CaptureCore
import CoreGraphics
import Foundation

/// The taught REC indicator's controller half: the four things the operator does
/// to teach it, what the panel reads back, and what of it survives a relaunch.
///
/// **The interaction, and why it is this one.** Cameras send their own UI down
/// the monitoring output, so the record indicator on screen can drive the take —
/// but ARRI, RED, Sony and Blackmagic put it in different places with different
/// glyphs, so nothing here recognises anything. The operator teaches it in four
/// steps and no more:
///
/// 1. **Mark on picture** arms teaching mode. The current box is drawn over the
///    live image and a click moves its CENTRE — one click, exactly the chroma
///    eyedropper's gesture and through exactly its inverse mapping
///    (`ViewAssist.imageFraction`), so it lands on the pixel under the pointer
///    through a desqueeze, a punch-in and a pan. A click and not a drag-marquee
///    on purpose: a marquee is a second gesture to invent, to teach and to get
///    wrong near the frame edge, and the size it would set is one slider.
/// 2. **Size** grows or shrinks the box around that centre, live on the picture.
/// 3. **Learn rolling** while the camera is rolling, **Learn idle** while it is
///    not. Two presses, each a snapshot of the box.
/// 4. **On.**
///
/// Between 3 and 4 the panel shows the separation the two references achieved
/// and the reading the box is producing right now, because those are the only
/// two things that say whether the teaching worked — and if the separation is
/// under `VisualRecTeaching.minSeparation` the trigger refuses to arm at all
/// rather than arming on a box that cannot tell the two apart.
extension CaptureController {
    /// Every write to `visualRecTeaching` lands here (from its didSet): the
    /// value goes to the pipeline, which is the only thing that acts on it, and
    /// the half of it that outlives a session is persisted. One door, so a row
    /// in the panel cannot forget either.
    func applyVisualRecChange(from oldValue: VisualRecTeaching) {
        guard oldValue != visualRecTeaching else { return }
        // The pipeline gets it AT ONCE — that is what makes the box follow the
        // pointer, and it is one struct copy onto a queue.
        pipeline.setVisualRec(visualRecTeaching)
        // The settings write is DEBOUNCED, on the same 400 ms the volume slider
        // and the DIM hold already use and for exactly the same reason: a
        // settings write fans out through `applySettingsChange` and re-renders
        // the window, and this value moves with a drag. Persisting every tick
        // of a drag across the picture is what made dragging the box sluggish
        // (owner: "перетаскивание марка река по визуалу лагает").
        visualRecPersistTask?.cancel()
        visualRecPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistVisualRec()
        }
    }

    // MARK: - the switch and the dials

    /// Opt-in, never a default, and never persisted — see
    /// `VisualRecSettings.centerX` for the reasoning.
    ///
    /// It cannot be switched on until the two references separate. Enforced in
    /// the SETTER and not only by disabling the switch: the panel's row is one
    /// caller, the hotkeys and the web remote could be the next, and "armed but
    /// untaught" is a state the readout would have to describe and the trigger
    /// could not honour.
    /// Whether the trigger is live. DRIVEN BY THE MODE now, not by a switch of
    /// its own — see `RecDetectionMode.visual`. Still refuses to be true while
    /// untaught, in the setter and not only by disabling a control: the mode
    /// can be chosen from a settings blob or before the box is taught, and
    /// "armed but untaught" is a state the readout would have to describe and
    /// the trigger could not honour.
    var visualRecOn: Bool {
        get { visualRecTeaching.isOn }
        set {
            var teaching = visualRecTeaching
            teaching.isOn = newValue && teaching.isTaught
            visualRecTeaching = teaching
            // teaching mode is for setting the box up; leaving the crosshair and
            // the rectangle on the picture once the trigger is live reads as a
            // stuck mode, and the box is the last thing an operator wants over
            // the frame while the unit is shooting
            if visualRecTeaching.isOn { visualRecTeachArmed = false }
        }
    }

    var visualRecWidth: Double {
        get { visualRecTeaching.region.width }
        set {
            var teaching = visualRecTeaching
            teaching.region.width = newValue
            teaching.clamp()
            visualRecTeaching = teaching
        }
    }

    var visualRecHeight: Double {
        get { visualRecTeaching.region.height }
        set {
            var teaching = visualRecTeaching
            teaching.region.height = newValue
            teaching.clamp()
            visualRecTeaching = teaching
        }
    }

    /// The margin, for the READOUT only — it is derived from the taught
    /// separation now and there is nothing to set. See
    /// `VisualRecTeaching.margin`.
    var visualRecMargin: Double { visualRecTeaching.margin }

    // MARK: - marking the box

    /// Arm or disarm teaching mode.
    ///
    /// Arming CLOSES the Settings-side popover nothing here owns and does not
    /// need to: the panel lives in the Settings window, not over the picture, so
    /// unlike the eyedropper there is no popover in the way of the click.
    func toggleVisualRecTeach() {
        visualRecTeachArmed.toggle()
        // Two modes waiting for a click on the same pixels is one mode too many:
        // whichever overlay is on top eats it, and the operator's other
        // crosshair silently does nothing. The eyedropper gives way.
        if visualRecTeachArmed { chromaPickArmed = false }
    }

    /// A click on the preview at `point`, on a `viewport`-sized surface (view
    /// coordinates, y down): the box's centre moves there.
    ///
    /// The point goes through the SAME placement inverse the eyedropper uses, so
    /// what is stored is a signal fraction and the box therefore survives every
    /// geometry change the viewer can make — that is the whole reason the region
    /// is not in viewport units. A click on the letterbox is ignored: there is no
    /// signal pixel there to name.
    /// Draw the box between two points on the picture.
    ///
    /// The crosshair over this overlay promised exactly this and delivered a
    /// move (owner: "курсор превращается в крестик, подразумевая что можно
    /// нарисовать область нужную, но это невозможно"). Both corners go through
    /// `imageFraction`, so a rubber band that starts on the picture and ends on
    /// the letterbox is refused rather than clamped to a shape the operator did
    /// not draw — the same rule a click outside the picture already follows.
    ///
    /// A band smaller than the floor is a CLICK, not a box, and is answered by
    /// moving the centre instead: that is what a tap has always done, and
    /// making a stray 2-pixel drag redefine the region would lose the taught
    /// shape to a twitch.
    func drawVisualRecRegion(from start: CGPoint, to end: CGPoint,
                             viewport: CGSize) {
        let source = displaySourceSize()
        guard let a = liveAssist.imageFraction(of: start, sourceSize: source,
                                               in: viewport),
              let b = liveAssist.imageFraction(of: end, sourceSize: source,
                                               in: viewport) else { return }
        let width = abs(Double(b.x - a.x))
        let height = abs(Double(b.y - a.y))
        guard width >= VisualRecRegion.minSize,
              height >= VisualRecRegion.minSize else {
            placeVisualRecRegion(at: end, viewport: viewport)
            return
        }
        var teaching = visualRecTeaching
        teaching.region.centerX = Double(a.x + b.x) / 2
        teaching.region.centerY = Double(a.y + b.y) / 2
        teaching.region.width = width
        teaching.region.height = height
        teaching.clamp()
        visualRecTeaching = teaching
    }

    func placeVisualRecRegion(at point: CGPoint, viewport: CGSize) {
        guard let fraction = liveAssist.imageFraction(
            of: point, sourceSize: displaySourceSize(), in: viewport) else { return }
        var teaching = visualRecTeaching
        teaching.region.centerX = Double(fraction.x)
        teaching.region.centerY = Double(fraction.y)
        teaching.clamp()
        visualRecTeaching = teaching
    }

    // MARK: - capturing the two references

    /// Snapshot the box as it looks right now, as one of the two references.
    ///
    /// Capturing a reference switches the trigger OFF if it was on: the frame
    /// that follows is being judged against a pair that has just changed, and
    /// re-arming is one click the operator makes once they have seen the new
    /// separation.
    func learnVisualRec(_ which: VisualRecReading) {
        guard let signature = pipeline.captureVisualRecSignature() else {
            lastError = L("visual_rec_learn_failed")
            return
        }
        var teaching = visualRecTeaching
        switch which {
        case .rolling: teaching.rolling = signature
        case .idle: teaching.idle = signature
        }
        teaching.isOn = false
        visualRecTeaching = teaching
        lastNotice = teaching.isTaught
            ? L("visual_rec_taught", visualRecSeparationText ?? "")
            : L("visual_rec_learned_one")
    }

    /// Forget both references, keeping the box and the margin — what a re-teach
    /// is after the camera's overlay changes.
    func forgetVisualRecReferences() {
        var teaching = visualRecTeaching
        teaching.forgetReferences()
        visualRecTeaching = teaching
    }

    // MARK: - what the panel reads back

    /// The trigger can be switched on: the two references exist and separate.
    /// The switch's own enabling rule, named here beside the setter that
    /// enforces the same thing (see `visualRecOn`).
    var canUseVisualRec: Bool { visualRecTeaching.isTaught }

    /// There is something to forget — one reference is enough, since half a
    /// teaching is exactly the state the operator wants to clear and start
    /// again from.
    var hasVisualRecReferences: Bool {
        visualRecTeaching.rolling != nil || visualRecTeaching.idle != nil
    }

    /// The taught separation in code values, or nil before both references
    /// exist.
    var visualRecSeparationText: String? {
        visualRecTeaching.separation.map { String(format: "%.1f", $0) }
    }

    /// One line saying exactly where the teaching stands. Three states, because
    /// there are three: nothing taught, taught but the pair does not separate,
    /// and ready.
    var visualRecStatus: String {
        guard let separation = visualRecSeparationText else {
            return visualRecTeaching.rolling == nil && visualRecTeaching.idle == nil
                ? L("visual_rec_status_untaught")
                : L("visual_rec_status_half")
        }
        return visualRecTeaching.isTaught
            ? L("visual_rec_status_ready", separation)
            : L("visual_rec_status_weak", separation)
    }

    /// The live reading, as the panel prints it.
    var visualRecReadingText: String {
        switch visualRecReading {
        case .rolling: return L("visual_rec_reading_rolling")
        case .idle: return L("visual_rec_reading_idle")
        case nil: return L("visual_rec_reading_none")
        }
    }

    /// The REC indicator over the player, with the trigger that rolled the take.
    ///
    /// Nobody can diagnose a spurious roll from a red dot that says only "REC",
    /// and this is the surface the person who notices one is looking at. A take
    /// whose trigger was not recorded — one already rolling when the app adopted
    /// it — gets the plain word rather than a guess.
    var recBadgeText: String {
        guard let recTrigger else { return L("rec") }
        return "\(L("rec")) · \(L(recTrigger.labelKey))"
    }

    // MARK: - persistence

    /// The teaching survives a relaunch; the switch does not (see
    /// `VisualRecSettings.centerX`). Everything is stored as nil at its
    /// default — the same convention as every other added field — and the whole
    /// blob is assigned once, because each write to `settings` runs the change
    /// handler.
    func persistVisualRec() {
        let teaching = visualRecTeaching
        let base = VisualRecTeaching()
        var updated = settings
        updated.visualRec.centerX = teaching.region.centerX
            == base.region.centerX ? nil : teaching.region.centerX
        updated.visualRec.centerY = teaching.region.centerY
            == base.region.centerY ? nil : teaching.region.centerY
        // The retired square key is cleared rather than carried: a value left
        // there would be read back by `restoreVisualRec` on the next launch and
        // would overwrite the pair the operator just set.
        updated.visualRec.size = nil
        updated.visualRec.width = teaching.region.width == base.region.width
            ? nil : teaching.region.width
        updated.visualRec.height = teaching.region.height
            == base.region.height ? nil : teaching.region.height
        // Derived from the separation, so there is nothing to store. The key
        // is cleared rather than left: a value there would be read by an older
        // build as a margin an operator chose, which nobody ever did.
        updated.visualRec.margin = nil
        updated.visualRec.rolling = teaching.rolling?.encoded
        updated.visualRec.idle = teaching.idle?.encoded
        guard updated != settings else { return }
        settings = updated
    }

    /// Restore the teaching at launch — switched OFF, whatever it was left at.
    func restoreVisualRec(from stored: VisualRecSettings) {
        var teaching = VisualRecTeaching()
        teaching.region.centerX = stored.centerX ?? teaching.region.centerX
        teaching.region.centerY = stored.centerY ?? teaching.region.centerY
        // The retired square key seeds BOTH axes, so a box taught before this
        // split comes back the shape it was left.
        teaching.region.width = stored.width ?? stored.size
            ?? teaching.region.width
        teaching.region.height = stored.height ?? stored.size
            ?? teaching.region.height
        // a blob that was truncated or hand-edited leaves the trigger untaught
        // rather than armed on garbage (see `VisualRecSignature.init(encoded:)`)
        teaching.rolling = stored.rolling
            .flatMap(VisualRecSignature.init(encoded:))
        teaching.idle = stored.idle
            .flatMap(VisualRecSignature.init(encoded:))
        teaching.clamp()
        teaching.isOn = false
        visualRecTeaching = teaching
    }
}
