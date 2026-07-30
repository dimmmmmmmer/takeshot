import AppKit

/// The grab-hand cursor over a punched-in picture.
///
/// Split out of `AssistZoomEvents`: the pinch/scroll input and the pointer are
/// separate jobs, and this one is the fussier of the two — the bounds are the
/// whole player, so every control inside them sets a cursor of its own and this
/// must not fight them.
extension PunchEventView {

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // tracking areas are geometry, not hit testing: they still fire for a
        // view that declines every click
        // mouseMoved as well as cursorUpdate: AppKit re-asserts the cursor as
        // the pointer travels, and a hand that only appears on entry is a hand
        // that vanishes the moment the operator moves
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp,
                                            .mouseEnteredAndExited,
                                            .mouseMoved,
                                            .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
        releaseCursor()
    }

    /// Assert the grab hand — and ONLY that.
    ///
    /// `mouseMoved` fires for every pointer move inside these bounds, and the
    /// bounds are the whole player: the transport slider, the wipe handle and
    /// the badges are all inside them and set cursors of their own. Setting a
    /// cursor unconditionally from here — an arrow whenever there was nothing to
    /// grab — beat every one of them to it and flickered the pointer over the
    /// controls. So nothing is asserted unless there is something to grab.
    private func applyCursor() {
        if isPunchedIn() {
            NSCursor.openHand.set()
        } else {
            releaseCursor()
        }
    }

    /// Put the arrow back, but only over a hand.
    ///
    /// The test is what is ON SCREEN rather than a flag we kept, because the two
    /// hands have two authors: the open one here and the closed one the drag
    /// gesture sets (`PunchInZoomModifier`). A flag owned by one of them leaks
    /// the other's cursor — punch in by hotkey, drag, punch out, and the hand
    /// stays over the whole window. The cursor classes are shared singletons, so
    /// identity is the honest question to ask.
    private func releaseCursor() {
        let current = NSCursor.current
        guard current === NSCursor.openHand
                || current === NSCursor.closedHand else { return }
        NSCursor.arrow.set()
    }

}
