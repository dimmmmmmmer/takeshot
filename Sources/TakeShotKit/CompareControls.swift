import SwiftUI

/// Live/playback compare controls.
///
/// **The bar collapses to the way IN, and that is the whole reachability of
/// live compare.** In record mode the B side is the pinned reference, and
/// `ComparePinControls` is the only thing anywhere in the app that can pin one
/// — `pinReferenceFromCurrentFrame()` has no menu item, no hotkey and no remote
/// command. The row used to be mounted only once something was already pinned
/// (see `CaptureController.showsCompareBar`), so from a fresh install with a
/// live signal the operator could not reach it at all: the key was inside the
/// lock, exactly as it was for the taught REC indicator. No test saw it because
/// every compare test set `referencePinned = true` first and then measured how
/// WIDE the bar came out.
///
/// So the bar is offered whenever there is a frame to pin, and everything that
/// needs a B side is left out until there is one. That is not only a way in: a
/// mode picker with nothing pinned changes nothing at all — `pushCompare` sends
/// `.off` to the pipeline while `referencePinned` is false — so the collapsed
/// bar is also the honest one.
struct CompareControls: View {
    /// Tighter than the shared plate inset: this is a row of six controls that
    /// carry their own margins, and the full 8pt a side pushed it into the badge
    /// groups it is centered between at the narrowest window.
    static let platePadding: CGFloat = 5

    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 8) {
            if controller.compareHasBSide {
                modePicker
                if controller.compareMode == .wipe { wipePicker }
                // The wipe has its seam and the blend its slider; difference has
                // its gain — the same control family, in the same slot. No wipe
                // position anywhere near it: a seam through |A−B| means nothing.
                if controller.compareMode == .difference { gainPicker }
                // The B-side menu belongs to an ENGAGED compare (it names the
                // other half), so the resting bar goes without it: with five
                // modes in the picker, the off state has to fit the centered
                // slot between the badge groups, and the menu is what it can
                // spare — engaging any mode brings it back, and picking a B clip
                // arms the wipe anyway. It stays while a B clip is chosen with
                // the compare off, so the choice never becomes invisible.
                if controller.viewerMode == .playback,
                   controller.rawPlayer == nil,
                   controller.compareMode != .off || controller.compareClipURL != nil {
                    bSideMenu
                }
            }
            ComparePinControls()
            if controller.compareHasBSide, controller.compareMode == .blend {
                blendControls
            }
        }
        // same plate as the badges and the mode switch above it (see PlayerChrome)
        .playerChromePlate(horizontalPadding: Self.platePadding)
    }

    private var modePicker: some View {
        Picker("", selection: $controller.compareMode) {
            Text(controller.viewerMode == .record
                 ? L("compare_source") : L("compare_off"))
                .tag(CaptureController.CompareMode.off)
            Text(L("compare_wipe")).tag(CaptureController.CompareMode.wipe)
            Text(L("compare_blend")).tag(CaptureController.CompareMode.blend)
            Text(L("compare_difference"))
                .tag(CaptureController.CompareMode.difference)
            Text(L("compare_side")).tag(CaptureController.CompareMode.sideBySide)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .controlSize(.mini)
    }

    private var wipePicker: some View {
        Picker("", selection: $controller.wipeOrientation) {
            Image(systemName: "rectangle.split.2x1")
                .tag(CaptureController.WipeOrientation.vertical)
                .help(L("wipe_vertical"))
            Image(systemName: "rectangle.split.1x2")
                .tag(CaptureController.WipeOrientation.horizontal)
                .help(L("wipe_horizontal"))
            Image(systemName: "line.diagonal")
                .tag(CaptureController.WipeOrientation.diagonal)
                .help(L("wipe_diagonal"))
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .controlSize(.mini)
    }

    private var gainPicker: some View {
        Picker("", selection: $controller.differenceGain) {
            ForEach(CaptureController.DifferenceGain.allCases) { gain in
                Text(gain.label).tag(gain)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .controlSize(.mini)
        .help(L("difference_gain_help"))
    }

    @ViewBuilder private var blendControls: some View {
        BlendControls(live: controller.compareLive) {
            controller.blendOpacity = $0
        }
    }

    /// What the other half of the compare is. The takes and the Other content
    /// come through the shared picker, under their own headings — this menu
    /// used to list the takes alone, in one flat run (owner item 36).
    private var bSideMenu: some View {
        Menu {
            Button {
                controller.compareClipURL = nil
            } label: {
                if controller.compareClipURL == nil {
                    Label(L("compare_b_live"), systemImage: "checkmark")
                } else {
                    Text(L("compare_b_live"))
                }
            }
            Divider()
            MediaSourceMenuItems(groups: controller.mediaSources(.video),
                                 selection: controller.compareClipURL) { url in
                controller.compareClipURL = url
            }
        } label: {
            // a clip the folder scan has not caught up with still names itself,
            // rather than reading as "vs Live" while a B clip is loaded
            Text(controller.compareClipURL.map {
                controller.mediaSourceName(for: $0) ?? $0.lastPathComponent
            } ?? L("compare_b_live"))
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 120)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("compare_b_help"))
    }
}

/// Pinning the reference, and letting it go again.
///
/// A view of its own rather than two more lines in the bar, and that is a
/// test's requirement rather than a layout's — the same reason
/// `VisualRecTeachRow` is one: this pair is the door into live compare, and a
/// suite that can only measure the bar as a block cannot say whether the door
/// is in it. `ViewPlayerBadgeTests` measures it on its own and holds the
/// unpinned record bar against exactly this and nothing else.
struct ComparePinControls: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // **The pin is offered where there is something worth pinning FROM.**
        //
        // It used to hang in the row permanently, including a record mode with
        // nothing on screen but the live signal (owner: "даже в режиме record
        // у меня всегда висит кнопка пина. она должна быть видна тогда когда я
        // включил какой либо записанный шот/other content в просмотре").
        //
        // Reviewing a clip is also the case the method is BUILT around: from
        // playback it takes the frame on screen, hands it to the pipeline as
        // the reference and switches the viewer back to record — so the live
        // picture is then being compared against a frame of a take, which is
        // the reason live compare exists. `isReviewingSingleClip` rather than
        // `playbackURL != nil` because a sync-play grid leaves the single
        // player parked and loaded, and the frame it would pin is one nobody
        // can see.
        //
        // The UNPIN stays unconditional, one line down: a reference pinned in
        // playback outlives the mode switch that pinning performs, so the way
        // out has to exist in the mode the pin drops you into.
        if controller.isReviewingSingleClip {
            Button {
                controller.pinReferenceFromCurrentFrame()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L("pin_reference_help"))
        }
        if controller.referencePinned {
            Button {
                controller.unpinReference()
            } label: {
                Image(systemName: "pin.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("unpin_reference_help"))
        }
    }
}

/// The blend slider and its percentage, observing `CompareLive` directly.
///
/// **A view of its own because the value it shows is not on the controller any
/// more.** `blendOpacity` was moved off `CaptureController` so a drag would
/// stop waking 114 `@EnvironmentObject` sites per tick — that is what fixed the
/// lag the owner reported on the wipe and the blend. What it left behind was
/// this row: the controller's property is a plain forwarder now, so binding to
/// it publishes nothing and the "%" beside the slider showed whatever number
/// happened to be there at the last unrelated publish. An operator dialling an
/// exact opacity was reading a figure that disagreed with the picture.
///
/// The same shape `WipeHandle` already uses one file over, and for the same
/// reason: the object that actually changes is the one to observe.
private struct BlendControls: View {
    @ObservedObject var live: CompareLive
    /// Written through the controller, which is what pushes the value into the
    /// pipeline and persists it on the debounce.
    ///
    /// `@MainActor`, because that is where the controller lives and where the
    /// call site mutates it. A `Binding`'s setter is `@Sendable`, so the two
    /// meet through `assumeIsolated` below: SwiftUI drives a setter on the main
    /// thread, and assuming it (rather than hopping with a Task) keeps the
    /// write synchronous with the drag — a hop would put the pipeline one
    /// event behind the slider.
    let onChange: @MainActor (Double) -> Void

    var body: some View {
        Slider(value: Binding(get: { live.blendOpacity },
                              set: { value in
                                  MainActor.assumeIsolated { onChange(value) }
                              }),
               in: 0...1)
            .frame(width: 90)
            .controlSize(.mini)
        TextField("", value: Binding(
            get: { Int((live.blendOpacity * 100).rounded()) },
            set: { value in
                MainActor.assumeIsolated {
                    onChange(Double(min(100, max(0, value))) / 100)
                }
            }),
            format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 30)
            .controlSize(.mini)
        Text("%")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
