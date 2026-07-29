import CaptureCore
import SwiftUI

/// The color a marker name maps to (palette in TakeMarker.colors).
func markerColor(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "yellow": return .yellow
    case "green": return .green
    case "cyan": return .cyan
    case "blue": return .blue
    case "purple": return .purple
    default: return .orange
    }
}

/// Add-marker flag + the marker list editor, for both transports.
struct MarkerButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @State private var showList = false

    var body: some View {
        Button {
            controller.addMarker()
        } label: {
            Image(systemName: "flag.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("\(L("marker_add_help")) — \(hotkeys.combo(for: .addMarker).display)")

        if !controller.playbackMarkers.isEmpty {
            Button {
                controller.jumpToMarker(forward: false)
            } label: {
                Image(systemName: "chevron.backward.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_prev_help"))

            Button {
                showList.toggle()
            } label: {
                Text("\(controller.playbackMarkers.count)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_list_help"))
            .popover(isPresented: $showList, arrowEdge: .top) {
                MarkerListEditor()
            }

            Button {
                controller.jumpToMarker(forward: true)
            } label: {
                Image(systemName: "chevron.forward.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_next_help"))
        }
    }
}

/// Popover list: jump to, recolor, annotate and delete markers.
private struct MarkerListEditor: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("markers_title"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("markers_clear_all"), role: .destructive) {
                    controller.clearPlaybackMarkers()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            }
            Divider()
            ForEach(Array(controller.playbackMarkers.enumerated()),
                    id: \.offset) { index, marker in
                HStack(spacing: 8) {
                    Text(marker.note.isEmpty
                         ? L("marker_n", index + 1) : marker.note)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .leading)
                    // color swatch: click cycles the palette (a menu on a
                    // 10 px label was unopenable)
                    Button {
                        let palette = TakeMarker.colors
                        let next = palette[
                            ((palette.firstIndex(of: marker.color) ?? 0) + 1)
                                % palette.count]
                        controller.updatePlaybackMarker(at: index) {
                            $0.color = next
                        }
                    } label: {
                        Circle()
                            .fill(markerColor(marker.color))
                            .frame(width: 12, height: 12)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("marker_color_help"))

                    Button {
                        controller.seekPlayback(to: marker.seconds)
                    } label: {
                        Text(marker.timecodeText.isEmpty
                             ? TransportBar.timeText(marker.seconds)
                             : marker.timecodeText)
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .help(L("marker_jump_help"))

                    TextField(L("marker_note_placeholder"), text: Binding(
                        get: { controller.playbackMarkers[safe: index]?.note ?? "" },
                        set: { note in
                            controller.updatePlaybackMarker(at: index) {
                                $0.note = note
                            }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 180)

                    Button {
                        controller.removePlaybackMarker(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("marker_delete_help"))
                }
            }
        }
        .padding(12)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Marker positions over a transport slider (display only).
struct MarkerTicks: View {
    let markers: [TakeMarker]
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                if duration > 0 {
                    Rectangle()
                        .fill(markerColor(marker.color))
                        .frame(width: 2, height: 7)
                        .position(
                            x: geo.size.width
                                * min(1, max(0, marker.seconds / duration)),
                            y: geo.size.height - 3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
