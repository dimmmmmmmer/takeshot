import SwiftUI

private struct ScopeGridBrightnessKey: EnvironmentKey {
    static let defaultValue: Double = 0.5
}

/// The value scale the panel's toolbar is set to. In the environment rather
/// than passed down: every scope's metric numbers read it now — the histogram's
/// used to be hard-coded 8-bit codes that no control could reach, which is the
/// asymmetry the owner spotted — and threading it through four trace views and
/// two graticules by hand is how the next one drifts out of step again.
private struct ScopeScaleModeKey: EnvironmentKey {
    static let defaultValue = ScopeScaleMode.percent
}

extension EnvironmentValues {
    var scopeGridBrightness: Double {
        get { self[ScopeGridBrightnessKey.self] }
        set { self[ScopeGridBrightnessKey.self] = newValue }
    }

    var scopeScaleMode: ScopeScaleMode {
        get { self[ScopeScaleModeKey.self] }
        set { self[ScopeScaleModeKey.self] = newValue }
    }
}

/// Drag-to-reorder for scope boxes.
///
/// Every hover writes VIEW STATE, never the defaults. `dropEntered` fires each
/// time the boxes move under the pointer — which the reorder itself causes — so
/// writing the persisted order there put a synchronous `UserDefaults` write and
/// a republish of the entire panel on the drag's own feedback loop. The
/// arrangement is committed once, when the drag ends.
struct ScopeDropDelegate: DropDelegate {
    let target: ScopeKind
    @Binding var dragged: ScopeKind?
    @Binding var live: [ScopeKind]?
    let commit: () -> Void
    let order: [ScopeKind]

    /// The order with the dragged box moved to the target's place, or nil when
    /// there is nothing to move. Pure, so the reorder can be tested without a
    /// drag session.
    static func reordered(_ order: [ScopeKind], moving dragged: ScopeKind?,
                          onto target: ScopeKind) -> [ScopeKind]? {
        guard let dragged, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return nil }
        var kinds = order
        kinds.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
        return kinds
    }

    func dropEntered(info: DropInfo) { hover() }

    func performDrop(info: DropInfo) -> Bool {
        drop()
        return true
    }

    /// What a hover does, without the `DropInfo` a test cannot construct: move
    /// the boxes, and touch nothing that outlives the drag.
    func hover() {
        guard let kinds = Self.reordered(order, moving: dragged, onto: target)
        else { return }
        live = kinds
    }

    /// What the release does — the one moment the arrangement is persisted.
    func drop() { commit() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Small channel selector shown in a scope's header (Y/RGB/R/G/B).
struct ChannelPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(selection == option
                                    ? AnyShapeStyle(.white.opacity(0.25))
                                    : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(selection == option
                                         ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// On/off chip in a scope's header, styled like the channel options beside it
/// (the vectorscope's skin-tone line).
struct ScopeChipToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(isOn
                            ? AnyShapeStyle(.white.opacity(0.25))
                            : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(isOn ? .white : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

/// Container for a single scope: a header row (name, per-scope controls) over
/// the trace canvas.
///
/// There is no longer a value-scale column beside the canvas. The numbers moved
/// INSIDE it, onto the graticule lines they belong to (`ScopeLevelGraticule`):
/// a column of numbers next to the box is a second, independently-positioned
/// copy of the axis, and it drifted off the lines it was naming as soon as the
/// map stopped putting 100 % on its top row.
///
/// `title` is empty when the panel shows ONE scope: the toggle row above
/// already names it, and repeating the name under it was one label too many for
/// a scope the size of the in-player overlay. `showsDragHandle` follows the same
/// logic — the grip means "drag to reorder", which is a lie when there is
/// nothing to reorder.
struct ScopeBox<Header: View, Content: View>: View {
    let title: String
    var showsDragHandle = false
    /// Trace canvas opacity: the in-player overlay lets the picture ghost
    /// through, the window is a window.
    var canvasOpacity: Double = 1
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    /// Nothing to put in it — a scope with no name, no grip and no controls of
    /// its own gets its full height for the trace.
    private var showsHeaderRow: Bool {
        showsDragHandle || !title.isEmpty || Header.self != EmptyView.self
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHeaderRow {
                HStack {
                    if showsDragHandle {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 6)
                    header
                }
            }
            content
                .frame(minWidth: 260, maxWidth: .infinity,
                       minHeight: 150, maxHeight: .infinity)
                .background(Color.black.opacity(canvasOpacity))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
