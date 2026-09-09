import SwiftUI

struct ContentView: View {
    // NOTE: the .id(appLanguage) below rebuilds the whole tree on a language
    // switch — cached L() strings in leaf views (the footer) survived otherwise.

    /// **The window's floor, and the two columns' floors, stated together.**
    ///
    /// They have to be one statement: the divider between the columns can only
    /// move what the two minimums do not already claim, so a main column that
    /// asks for less than "the window minus the panel" is a divider that can
    /// steal width from the footer. It could — 1080 window, 330 of panel, and
    /// a main column that declared 680 — so at the narrowest window the
    /// divider had 70pt of slack and dragging it broke the bottom bar (owner:
    /// "давай сделаем так чтобы по ширине на минимальном экране нельзя было
    /// двигать размер блока тейков и другого контента – это ломает юи нав бара
    /// внизу").
    ///
    /// Derived rather than typed, so the arithmetic cannot drift: at exactly
    /// `windowMinWidth` the two floors add up to the whole window and the
    /// divider has nothing to give. Wider than that, it moves again — which is
    /// the point of having one at all.
    ///
    /// `ViewBudget` in the test target reads these, so the width the footer is
    /// MEASURED against and the width it is GUARANTEED are the same number.
    nonisolated static let windowMinWidth: CGFloat = 1080
    nonisolated static let windowMinHeight: CGFloat = 620
    /// The takes/other-content column at its narrowest, and the padding around
    /// it that `sidePanel` applies.
    nonisolated static let panelMinWidth: CGFloat = 310
    nonisolated static let panelMaxWidth: CGFloat = 480
    nonisolated static let panelPadding: CGFloat = 10
    /// What the panel occupies including its padding.
    nonisolated static var panelOuterMinWidth: CGFloat { panelMinWidth + 2 * panelPadding }
    /// …and therefore what the player column may never go below.
    nonisolated static var mainColumnMinWidth: CGFloat {
        windowMinWidth - panelOuterMinWidth
    }

    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HSplitView {
            if controller.panelSide == "left" {
                sidePanel
            }
            mainColumn
            if controller.panelSide == "right" {
                sidePanel
            }
        }
        .background(controller.appBackground.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        // The window's top strip answers the mouse like a title bar: drag to
        // move, double-click for whatever the Mac is set to do (see
        // `WindowDragZone`).
        //
        // **BEHIND the content, not over it.** As an overlay it took every
        // click in that band — and the player's top control row is drawn in
        // it, so the whole row went dead (owner: "на последней сборке вся
        // верхняя строчка управления не работает"). This is the same shape
        // `TakeListView` uses for its focus target and for the same reason: a
        // full-width view in front of controls is those controls unreachable.
        //
        // It only receives what nothing in front of it claims, which is why
        // the spacer in `mainColumn` had to stop hit-testing — a `Color.clear`
        // IS hit-tested, and it is exactly the empty strip this wants.
        .background(alignment: .top) {
            WindowDragZone()
                .frame(height: controller.windowTopInset)
        }
        .id(controller.settings.theme.appLanguage)
        // The DIT offload runs as a sheet over the main window: it needs a
        // destination LIST, live per-destination progress and a verdict card
        // each, none of which a chain of modal file panels can show.
        .sheet(isPresented: $controller.offloadSheetPresented) {
            OffloadSheet(model: controller.offload,
                         history: controller.offloadHistory,
                         ledger: controller.offloadedCards)
                // Re-injected rather than inherited, the way `SlateFields`
                // does it for its popover: a presentation is hosted in its own
                // context, and a view inside it reaching for an
                // `@EnvironmentObject` that never arrived does not degrade —
                // it traps. The sheet's footer and its remembered-cards list
                // both need the controller.
                .environmentObject(controller)
        }
        // …and the other half of the same job: re-reading a disk that was
        // offloaded weeks ago against the manifest left on it.
        .sheet(isPresented: $controller.verifySheetPresented) {
            OffloadVerifySheet(model: controller.verify)
        }
        // Dailies with burn-ins — a transcode queue over finished takes. A
        // sheet for the offload's reasons: burn-in switches, a destination
        // and a live run need more than a menu item can hold.
        .sheet(isPresented: $controller.dailiesSheetPresented) {
            DailiesSheet(model: controller.dailies)
        }
        // clicking empty space clears focus from text fields
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        // …and the window opens with nothing focused at all: Cam is the first
        // text field in the tree, so AppKit was aiming the keyboard at a
        // filename field before the operator had touched anything.
        .releasesInitialFocus()
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // strip the window keeps clear of the traffic lights; nothing is
            // mounted in it any more (the utility buttons spent a release there
            // and are under the takes panel now — see `sidePanel`)
            //
            // It does not hit-test: a clear colour normally does, and this one
            // sits over the window's drag strip (see the background above).
            // Reserving height is the whole of its job.
            Color.clear
                .frame(height: controller.windowTopInset)
                .allowsHitTesting(false)
            PlayerArea()
            BottomBarView()
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.08)))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: Self.mainColumnMinWidth, maxWidth: .infinity)
        .layoutPriority(1)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The takes panel, and under it — outside its plate, centred on its width —
    /// the settings/VANC/offload row (see `PanelUtilityButtons`).
    ///
    /// Both are children of the same column and share its 10pt horizontal
    /// padding, so the row is centred on exactly the width the panel occupies:
    /// there is no second number to keep in step.
    private var sidePanel: some View {
        VStack(spacing: 8) {
            TakeListView()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.07)))
            PanelUtilityButtons()
        }
        // top edge flush with the player
        .padding(.top, controller.windowTopInset)
        .padding(.bottom, 10)
        .padding(.horizontal, Self.panelPadding)
        .frame(minWidth: Self.panelMinWidth, maxWidth: Self.panelMaxWidth)
        .ignoresSafeArea(.container, edges: .top)
    }
}
