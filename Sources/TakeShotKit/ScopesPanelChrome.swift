import AppKit
import CaptureCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's chrome: the toolbar above the scope boxes, the per-scope
/// controls inside each box header, and the value scale beside the trace.
///
/// In a file of its own because the panel body was the longest type in the app
/// and this half of it is a separate concern: what the operator switches on,
/// versus what gets drawn. Internal rather than private for that reason —
/// `ScopesPanel.body` is the only caller.
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

    @ViewBuilder var toggleRow: some View {
        ForEach(order) { kind in
            scopeToggle(L(kind.titleKey), isOn: isOn(kind))
        }
    }

    /// Value scale, graticule/trace brightness, and the reorder hint.
    @ViewBuilder var displayControls: some View {
        ChannelPicker(selection: $scaleMode, options: ["100", "1023"])
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

    @ViewBuilder var windowButtons: some View {
        if let onCloseWindow {
            Button {
                onCloseWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(L("close"))
        }
        if !controller.scopesWindowOpen {
            Button {
                openWindow(id: "scopes")
                controller.showScopesOverlay = false
            } label: {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L("scope_open_window"))
        }
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

    /// Value marks for waveform/parade: percent or 10-bit code values.
    var percentScale: some View {
        let marks: [Int] = scaleMode == "1023"
            ? [1023, 896, 768, 640, 512, 384, 256, 128, 0]
            : [100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0]
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(marks, id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35 + gridBrightness * 0.45))
                    .frame(maxHeight: .infinity,
                           alignment: mark == marks.first ? .top
                               : (mark == 0 ? .bottom : .center))
            }
        }
        .frame(width: 26)
        .frame(maxHeight: .infinity)
    }
}
