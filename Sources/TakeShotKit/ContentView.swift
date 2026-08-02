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
        .id(controller.settings.appLanguage)
        // The DIT offload runs as a sheet over the main window: it needs a
        // destination LIST, live per-destination progress and a verdict card
        // each, none of which a chain of modal file panels can show.
        .sheet(isPresented: $controller.offloadSheetPresented) {
            OffloadSheet(model: controller.offload,
                         history: controller.offloadHistory)
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
            // strip under the window buttons — the actual height of their area
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

    private var sidePanel: some View {
        TakeListView()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.07)))
            // BELOW the panel's chrome, not inside it: the settings/VANC/
            // offload strip is its own plate, centered on the panel's width
            // (owner item 2).
            .takesPanelUtilityStrip()
            // top edge flush with the player
            .padding(.top, controller.windowTopInset)
            .padding(.bottom, 10)
            .padding(.horizontal, 10)
            .frame(minWidth: 310, maxWidth: 480)
            .ignoresSafeArea(.container, edges: .top)
    }
}
