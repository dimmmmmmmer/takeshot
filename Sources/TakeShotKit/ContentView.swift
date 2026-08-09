import SwiftUI

struct ContentView: View {
    // NOTE: the .id(appLanguage) below rebuilds the whole tree on a language
    // switch — cached L() strings in leaf views (the footer) survived otherwise.

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
            Color.clear.frame(height: controller.windowTopInset)
            PlayerArea()
            BottomBarView()
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.08)))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 680, maxWidth: .infinity)
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
        .padding(.horizontal, 10)
        .frame(minWidth: 310, maxWidth: 480)
        .ignoresSafeArea(.container, edges: .top)
    }
}
