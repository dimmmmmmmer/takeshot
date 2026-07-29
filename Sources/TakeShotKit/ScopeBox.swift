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

/// Titled container for a single scope with an optional channel picker and scale.
struct ScopeBox<Content: View, Scale: View>: View {
    let title: String
    let channel: ChannelPicker?
    @ViewBuilder let content: Content
    @ViewBuilder let scale: Scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 6)
                if let channel {
                    channel
                }
            }
            HStack(spacing: 2) {
                content
                    .frame(minWidth: 260, maxWidth: .infinity,
                           minHeight: 150, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                scale
            }
        }
    }
}
