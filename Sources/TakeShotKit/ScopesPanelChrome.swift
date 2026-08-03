import AppKit
import CaptureCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's chrome: the toolbar above the scope boxes and the per-scope
/// controls inside each box header.
///
/// In a file of its own because the panel body was the longest type in the app
/// and this half of it is a separate concern: what the operator switches on,
/// versus what gets drawn. Internal rather than private for that reason —
/// `ScopesPanel.body` is the only caller.
/// The panel's chrome buttons, in the order they are laid out left to right.
///
/// Close is LAST. It is the only control in the row that takes the scopes away,
/// so it goes at the far edge with nothing past it to be hit by mistake — and
/// the operator reaching for "open in a separate window" no longer crosses it
/// on the way. They were the other way round, which is what he reported.
enum ScopeChromeButton: String, CaseIterable, Identifiable {
    case openInWindow
    case close
    var id: String { rawValue }
}

extension ScopesPanel {
    /// The per-scope controls in a box header: channel choice where a scope has
    /// channels, the skin-tone line where it has one.
    @ViewBuilder
    func boxHeader(for kind: ScopeKind) -> some View {
        switch kind {
        case .waveform:
            ChannelPicker(selection: $waveformChannel,
                          options: ["y", "rgb", "r", "g", "b"])
        case .histogram:
            ChannelPicker(selection: $histogramChannel,
                          options: ["rgb", "y", "r", "g", "b"])
        case .vector:
            ScopeChipToggle(title: L("scope_skin_tone_short"), isOn: $skinToneOn)
                .help(L("scope_skin_tone"))
        case .parade:
            EmptyView()
        }
    }

    /// Panel chrome: the scope toggles plus the display controls.
    ///
    /// One row while it fits, two when it doesn't. The single row needs ~690pt
    /// in English and ~740 in Russian, and the panel declares a 420pt minimum
    /// width — shrink the scopes window and the toggles the operator came for
    /// were the first thing to get clipped.
    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                toggleRow
                Spacer()
                displayControls
                windowButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    toggleRow
                    Spacer()
                    windowButtons
                }
                HStack(spacing: 6) {
                    displayControls
                    Spacer()
                }
            }
        }
    }

    /// Shown only while the analyzer is reading the 10-bit wire instead of the
    /// display buffer. It is the answer to the question the new picture raises:
    /// "why is my trace above 100 now?" — because this is the signal the camera
    /// is sending, not the one the levels stage has already clipped.
    @ViewBuilder var wireBadge: some View {
        if scopes.data?.nominal.showsExcursions == true {
            Text(L("scope_wire_badge"))
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(controller.accentColor.opacity(0.35), in: Capsule())
                .foregroundStyle(.white.opacity(0.9))
                .help(L("scope_wire_hint"))
        }
    }

    /// The transfer of the frame currently on the scopes. `.sdr` when nothing
    /// has been analyzed yet, which is what keeps the toolbar unchanged until
    /// an HDR frame has actually arrived.
    var analyzedTransfer: SignalTransfer { scopes.data?.transfer ?? .sdr }

    /// Which value scales the picker offers. `nits` joins ONLY on a PQ or HLG
    /// frame, because there is nothing for it to compute on any other one —
    /// and because a third chip in that row on every SDR session would be
    /// paying for HDR with the toolbar of the ninety-nine shoots that are not.
    var scaleOptions: [String] {
        let base = [ScopeScaleMode.percent.rawValue,
                    ScopeScaleMode.tenBitCode.rawValue]
        guard analyzedTransfer.isHDR else { return base }
        return base + [ScopeScaleMode.nits.rawValue]
    }

    /// What the scopes are reading, when it is not Rec.709 SDR.
    ///
    /// Beside the wire badge and for the same reason it exists: the operator
    /// has to be able to answer "what am I looking at" without leaving the
    /// picture. A PQ trace at two thirds of the box is a correctly exposed
    /// face, and on an SDR scale it reads as blown.
    @ViewBuilder var hdrBadge: some View {
        if analyzedTransfer.isHDR {
            Text(analyzedTransfer.rawValue.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(controller.accentColor.opacity(0.55), in: Capsule())
                .foregroundStyle(.white.opacity(0.95))
                .help(L("scope_hdr_hint"))
        }
    }

    @ViewBuilder var toggleRow: some View {
        ForEach(order) { kind in
            scopeToggle(L(kind.titleKey), isOn: isOn(kind))
        }
    }

    /// Value scale, graticule/trace brightness, and the reorder hint.
    @ViewBuilder var displayControls: some View {
        wireBadge
        hdrBadge
        ChannelPicker(selection: $scaleMode, options: scaleOptions)
        HStack(spacing: 3) {
            Image(systemName: "grid")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
            Slider(value: $gridBrightness, in: 0.15...1)
                .frame(width: 56)
                .controlSize(.mini)
        }
        .help(L("scope_grid_brightness"))
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.45))
            Slider(value: $traceBrightness, in: 0.3...1)
                .frame(width: 56)
                .controlSize(.mini)
        }
        .help(L("scope_trace_brightness"))
        // Only where dragging actually does something: the boxes reorder in the
        // separate window, and only when there are at least two of them. The
        // in-player overlay showed this hint while holding exactly one scope
        // that cannot be dragged anywhere — the caption promised a feature the
        // surface does not have.
        if !singleScope, visibleScopes.count > 1 {
            // decorative: it truncates rather than wrapping the row onto a
            // second line when the translation is long
            Text(L("scope_drag_hint"))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    /// The two chrome buttons — and which surface gets which.
    ///
    /// The OVERLAY gets the close button. It floats over the picture with no
    /// frame of its own, so the only ways out of it were Esc and a click on the
    /// image: both real, neither visible. The WINDOW does not — it has a title
    /// bar with the system's own close button in it, and the X that used to sit
    /// in its content was a second control doing the same job two centimetres
    /// away from the first.
    ///
    /// The row is built by walking `ScopeChromeButton.allCases`, so the order
    /// declared there is the order drawn — it was hand-written the other way
    /// round and no test could see it.
    @ViewBuilder var windowButtons: some View {
        ForEach(ScopeChromeButton.allCases) { button in
            switch button {
            case .openInWindow:
                if !controller.scopesWindowOpen { openInWindowButton }
            case .close:
                if singleScope { closeButton }
            }
        }
    }

    private var openInWindowButton: some View {
        Button {
            AppWindows.present(.scopes, opening: openWindow)
            controller.showScopesOverlay = false
        } label: {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(L("scope_open_window"))
    }

    private var closeButton: some View {
        Button {
            controller.showScopesOverlay = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(L("close"))
    }

    func scopeToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn.wrappedValue
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                Text(title)
            }
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isOn.wrappedValue
                        ? AnyShapeStyle(controller.accentColor.opacity(0.35))
                        : AnyShapeStyle(.white.opacity(0.08)),
                        in: Capsule())
            .foregroundStyle(isOn.wrappedValue ? .white : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }
}
