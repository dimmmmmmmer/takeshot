import SwiftUI

private struct ScopeGridBrightnessKey: EnvironmentKey {
    static let defaultValue: Double = 0.5
}

extension EnvironmentValues {
    var scopeGridBrightness: Double {
        get { self[ScopeGridBrightnessKey.self] }
        set { self[ScopeGridBrightnessKey.self] = newValue }
    }
}

/// Drag-to-reorder for scope boxes.
struct ScopeDropDelegate: DropDelegate {
    let target: ScopeKind
    @Binding var dragged: ScopeKind?
    @Binding var orderRaw: String
    let order: [ScopeKind]

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        var kinds = order
        kinds.move(fromOffsets: IndexSet(integer: from),
                   toOffset: to > from ? to + 1 : to)
        orderRaw = kinds.map(\.rawValue).joined(separator: ",")
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }

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
/// the trace canvas, with an optional value scale beside it.
///
/// `title` is empty when the panel shows ONE scope: the toggle row above
/// already names it, and repeating the name under it was one label too many for
/// a scope the size of the in-player overlay. `showsDragHandle` follows the same
/// logic — the grip means "drag to reorder", which is a lie when there is
/// nothing to reorder.
struct ScopeBox<Header: View, Content: View, Scale: View>: View {
    let title: String
    var showsDragHandle = false
    /// Trace canvas opacity: the in-player overlay lets the picture ghost
    /// through, the window is a window.
    var canvasOpacity: Double = 1
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let scale: Scale

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
            HStack(spacing: 2) {
                content
                    .frame(minWidth: 260, maxWidth: .infinity,
                           minHeight: 150, maxHeight: .infinity)
                    .background(Color.black.opacity(canvasOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                scale
            }
        }
    }
}
