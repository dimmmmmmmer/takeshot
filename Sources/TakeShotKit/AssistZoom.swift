import AppKit
import CaptureCore
import SwiftUI

/// Punch-in zoom on a preview surface: trackpad pinch for the level, two-finger
/// scroll (momentum included) and drag for the pan, and a grab-hand cursor while
/// there is something to grab.
///
/// It hangs off `playerTopBadges`, which is the ONE mount the main player and
/// both fullscreen windows share. The pan gesture used to sit on the windowed
/// viewer surface alone, so punching in inside the fullscreen player left the
/// operator with a magnified image and no way to move it (item 19).
extension View {
    func punchInZoom() -> some View {
        modifier(PunchInZoomModifier())
    }
}

private struct PunchInZoomModifier: ViewModifier {
    @EnvironmentObject private var controller: CaptureController

    /// The surface the picture is fitted into — the pan converts pointer
    /// distance through it, so it has to be the size the renderer sees.
    @State private var viewport: CGSize = .zero
    @State private var lastTranslation: CGSize = .zero
    /// This drag is the one holding the picture — i.e. the closed hand on screen
    /// is ours to put back. A drag that never panned anything (not punched in,
    /// or a scrub that the transport took) must leave the cursor alone.
    @State private var grabbing = false

    func body(content: Content) -> some View {
        content
            // background, and hit-test-free besides: the transport bar and the
            // badges must keep every click they had before
            .background {
                GeometryReader { geo in
                    PunchEventSurface(controller: controller)
                        .onAppear { viewport = geo.size }
                        .onChange(of: geo.size) { _, size in viewport = size }
                }
            }
            // on the content, not an overlay: SwiftUI gives a child (the
            // transport, the wipe handle) priority over an ancestor's gesture
            .gesture(panGesture)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard controller.isPunchedIn else { return }
                if !grabbing {
                    grabbing = true
                    // AppKit suppresses cursor updates while a button is down,
                    // so the closed hand set here sticks for the whole drag —
                    // once is enough, and it is not re-set per event
                    NSCursor.closedHand.set()
                }
                let delta = CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                controller.panPunchIn(by: delta, viewport: viewport)
            }
            .onEnded { _ in
                lastTranslation = .zero
                if grabbing {
                    grabbing = false
                    // still magnified: back to the open hand, the operator can
                    // grab again. Zoomed out mid-drag: the arrow, because the
                    // closed hand on screen is one we put there.
                    (controller.isPunchedIn ? NSCursor.openHand : NSCursor.arrow)
                        .set()
                }
                // publish the finished pan now instead of waiting out the debounce
                controller.commitAssistDraft()
            }
    }
}
