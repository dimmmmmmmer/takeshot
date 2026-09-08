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
        // a write from anywhere else supersedes a draft the debounce has not
        // folded in yet — same rule, and the same reason, as `applyAssistChange`
        visualRecLive.settle(visualRecTeaching)
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

    /// The teaching as the picture is showing it: the draft while a drag or a
    /// slider is in flight, the published value otherwise.
    ///
    /// Every reader takes this rather than `visualRecTeaching` — the overlay
    /// that draws the box, the rows that read its size back, and the hit test
    /// that decides whether a press lands inside it. A reader that took the
    /// published value would be a frame behind the pointer, which for the hit
    /// test means the wrong half of the gesture.
    var liveVisualRec: VisualRecTeaching {
        visualRecLive.hasDraft ? visualRecLive.teaching : visualRecTeaching
    }

    /// Change the teaching from a DRAG: on screen and in the pipeline now,
    /// published once the gesture settles.
    ///
    /// The published write is what costs — it re-lays out every view observing
    /// the controller — so it happens once per gesture instead of once per
    /// tick. Same shape as `applyAssistPreview`, which is the control beside
    /// this one.
    func applyVisualRecPreview(_ change: (inout VisualRecTeaching) -> Void) {
        let current = liveVisualRec
        var draft = current
        change(&draft)
        // an unchanged value must not restart the debounce: a slider held at
        // its limit and a drag that has stopped moving are both this
        guard draft != current else { return }
        visualRecLive.preview(draft)
        pipeline.setVisualRec(draft)
        visualRecPersistTask?.cancel()
        visualRecPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.commitVisualRecDraft()
        }
    }

    /// Fold the draft into the published state — one re-render per gesture.
    func commitVisualRecDraft() {
        guard visualRecLive.hasDraft else { return }
        // didSet settles the draft, pushes the pipeline and persists
        visualRecTeaching = visualRecLive.teaching
    }

    /// Change the teaching from a CLICK (a switch, a capture, a reset):
    /// published at once, but a dragged value still on screen is folded in
    /// first — otherwise the click would throw away the box the operator has
    /// just let go of.
    func setVisualRec(_ change: (inout VisualRecTeaching) -> Void) {
        commitVisualRecDraft()
        var value = visualRecTeaching
        change(&value)
        visualRecTeaching = value
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
            setVisualRec { $0.isOn = newValue && $0.isTaught }
            // teaching mode is for setting the box up; leaving the crosshair and
            // the rectangle on the picture once the trigger is live reads as a
            // stuck mode, and the box is the last thing an operator wants over
            // the frame while the unit is shooting
            if visualRecTeaching.isOn { visualRecTeachArmed = false }
        }
    }

    var visualRecWidth: Double {
        get { liveVisualRec.region.width }
        set {
            applyVisualRecPreview {
                $0.region.width = newValue
                $0.clamp()
            }
        }
    }

    var visualRecHeight: Double {
        get { liveVisualRec.region.height }
        set {
            applyVisualRecPreview {
                $0.region.height = newValue
                $0.clamp()
            }
        }
    }

    /// The margin, for the READOUT only — it is derived from the taught
    /// separation now and there is nothing to set. See
    /// `VisualRecTeaching.margin`.
    var visualRecMargin: Double { liveVisualRec.margin }

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
    /// Whether a point on the picture is INSIDE the watched box.
    ///
    /// What the gesture and the cursor both ask, so they cannot disagree about
    /// which one the operator is about to get.
    func visualRecBoxContains(_ point: CGPoint, viewport: CGSize) -> Bool {
        guard let fraction = liveAssist.imageFraction(
            of: point, sourceSize: displaySourceSize(), in: viewport) else {
            return false
        }
        let box = liveVisualRec.region.normalizedBox
        return Double(fraction.x) >= box.x && Double(fraction.x) <= box.x + box.width
            && Double(fraction.y) >= box.y && Double(fraction.y) <= box.y + box.height
    }

    /// Drag the box to a new place, keeping its size.
    ///
    /// Moving and drawing are told apart by WHERE THE DRAG STARTED, not by how
    /// far it went. Deciding on the distance meant a short drag moved the box
    /// and a long one redrew it, which from the operator's side is the same
    /// gesture doing two different things at random (owner: "курсор при марке
    /// река визуального странно работает – то тащит, то рисует квадрат").
    /// Inside the box drags it; outside draws a new one; the cursor says which.
    /// **From the box the stroke STARTED on, not from wherever it is now.**
    ///
    /// `DragGesture.translation` is cumulative — the distance from the press,
    /// re-reported on every change event — and this added it each time. Ten
    /// points of movement arrived as 10, then 20, then 30, and the box had
    /// moved 60: it ran away from the pointer, faster the further the operator
    /// went, which is what a runaway feels like from the other side (owner:
    /// "чувствительность перетаскивания маркера слишком большая", "поле
    /// начинает оттаскиваться в сторону мышки").
    ///
    /// Taking the base as an argument rather than latching it here is what
    /// makes it right: the caller latches it at the press, so every event of
    /// the stroke is an absolute answer to the same question and the box cannot
    /// drift by accumulating its own output.
    func moveVisualRecRegion(_ base: VisualRecRegion, by translation: CGSize,
                             from start: CGPoint, viewport: CGSize) {
        let source = displaySourceSize()
        guard let from = liveAssist.imageFraction(of: start, sourceSize: source,
                                                  in: viewport),
              let to = liveAssist.imageFraction(
                of: CGPoint(x: start.x + translation.width,
                            y: start.y + translation.height),
                sourceSize: source, in: viewport) else { return }
        applyVisualRecPreview {
            $0.region = base
            $0.region.centerX = base.centerX + Double(to.x - from.x)
            $0.region.centerY = base.centerY + Double(to.y - from.y)
            $0.clamp()
        }
    }

    /// Draw the box between two points on the picture.
    ///
    /// The crosshair over this overlay promised exactly this and delivered a
    /// move (owner: "курсор превращается в крестик, подразумевая что можно
    /// нарисовать область нужную, но это невозможно"). Both corners go through
    /// `imageFraction`, so a rubber band that starts on the picture and ends on
    /// the letterbox is refused rather than clamped to a shape the operator did
    /// not draw — the same rule a click outside the picture already follows.
    ///
    /// A band smaller than the floor is a CLICK, and a click outside the box
    /// puts the box where it was clicked: that is what a tap has always done.
    /// Draw the box between two points on the picture.
    ///
    /// The crosshair over this overlay promised exactly this and delivered a
    /// move (owner: "курсор превращается в крестик, подразумевая что можно
    /// нарисовать область нужную, но это невозможно"). Both corners go through
    /// `imageFraction`, so a rubber band that starts on the picture and ends on
    /// the letterbox is refused rather than clamped to a shape the operator did
    /// not draw — the same rule a click outside the picture already follows.
    func drawVisualRecRegion(from start: CGPoint, to end: CGPoint,
                             viewport: CGSize) {
        let source = displaySourceSize()
        guard let a = liveAssist.imageFraction(of: start, sourceSize: source,
                                               in: viewport),
              let b = liveAssist.imageFraction(of: end, sourceSize: source,
                                               in: viewport) else { return }
        let drawnWidth = abs(Double(b.x - a.x))
        let drawnHeight = abs(Double(b.y - a.y))
        // A band under the floor does NOTHING. It used to place the box at the
        // pointer, which put a teleport at the start of every draw and moved
        // the box on a bare click (owner: "при клике на пустом пространстве в
        // режиме рисования области он сразу туда телепортит эту область").
        guard drawnWidth >= VisualRecRegion.minSize,
              drawnHeight >= VisualRecRegion.minSize else { return }
        // Capped HERE and anchored on the press, not clamped after centring on
        // the band: the box has a ceiling a quarter of the frame wide and a
        // mouse crosses it easily, and a centre computed from the band's middle
        // went on following the pointer once the size had saturated — a draw
        // that turned into a drag exactly when the sliders hit their end, which
        // is where the owner placed it ("потому что ползунки добегают до
        // максимума"). Anchored, the box grows away from the press and stops.
        let width = min(VisualRecRegion.maxSize, drawnWidth)
        let height = min(VisualRecRegion.maxSize, drawnHeight)
        applyVisualRecPreview {
            $0.region.centerX = Double(a.x) + (b.x >= a.x ? width : -width) / 2
            $0.region.centerY = Double(a.y) + (b.y >= a.y ? height : -height) / 2
            $0.region.width = width
            $0.region.height = height
            $0.clamp()
        }
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
        setVisualRec {
            switch which {
            case .rolling: $0.rolling = signature
            case .idle: $0.idle = signature
            }
            $0.isOn = false
        }
        let teaching = visualRecTeaching
        lastNotice = teaching.isTaught
            ? L("visual_rec_taught", visualRecSeparationText ?? "")
            : L("visual_rec_learned_one")
    }

    /// Forget both references, keeping the box and the margin — what a re-teach
    /// is after the camera's overlay changes.
    func forgetVisualRecReferences() {
        setVisualRec { $0.forgetReferences() }
    }

    // MARK: - what the panel reads back

    /// The trigger can be switched on: the two references exist and separate.
    /// The switch's own enabling rule, named here beside the setter that
    /// enforces the same thing (see `visualRecOn`).
    var canUseVisualRec: Bool { visualRecTeaching.isTaught }

    /// Visual detection is the chosen mode and the indicator has not been
    /// taught: the trigger stays off, nothing starts a take, and until this
    /// was said on screen an operator stood watching for takes that could not
    /// come (see `DetectionModePicker`).
    var visualRecNeedsTeaching: Bool {
        settings.capture.detectionMode == .visual && !canUseVisualRec
    }

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
