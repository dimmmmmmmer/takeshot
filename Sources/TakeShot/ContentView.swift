import AVFoundation
import CaptureCore
import SwiftUI

struct ContentView: View {
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
        // clicking empty space clears focus from text fields
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
            // top edge flush with the player
            .padding(.top, controller.windowTopInset)
            .padding(.bottom, 10)
            .padding(.horizontal, 10)
            .frame(minWidth: 310, maxWidth: 480)
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// Player card: TC, format, and the mode switch live right on it.
struct PlayerArea: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        PreviewView()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08)))
            .overlay {
                if controller.isRecording, controller.viewerMode == .record {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                overlayBadge {
                    Text(controller.currentTimecode?.description ?? "--:--:--:--")
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(
                            controller.isRecording && controller.viewerMode == .record
                            ? Color.red : Color.white)
                }
                // always in the left corner; vertical inset under the window buttons
                // is already reserved by the windowTopInset strip above the player
                .padding(.leading, 8)
                .padding(.top, 8)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    Picker("", selection: $controller.viewerMode) {
                        Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
                        Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .labelsHidden()
                    .controlSize(.small)

                    if controller.viewerMode == .playback,
                       controller.playbackURL != nil {
                        CompareControls()
                    }
                }
                .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    overlayBadge {
                        LUTMenu()
                    }
                    overlayBadge {
                        Group {
                            if let format = controller.signalFormat {
                                Text(Self.shortFormat(format)).monospacedDigit()
                            } else {
                                Text(L("no_signal_short"))
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                // player fullscreen — bottom-right (in playback this button is in the transport)
                if controller.viewerMode == .record {
                    Button {
                        controller.toggleLiveFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13))
                            .padding(6)
                            .background(.black.opacity(0.45),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(L("fullscreen"))
                    .padding(8)
                }
            }
            .overlay {
                if controller.showAudioPanel {
                    AudioChannelPanel()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if controller.showScopes {
                    ScopesPanel()
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: controller.lastError)
            .padding(.horizontal, 12)
    }

    private func overlayBadge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .foregroundStyle(.white) // readable on any player background (incl. black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    static func fpsText(_ fps: Double) -> String {
        fps.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(fps))
            : String(format: "%.2f", fps)
    }

    static func shortFormat(_ format: CaptureFormat) -> String {
        "\(format.height)p\(fpsText(format.frameRate))"
    }
}

/// LUT: choose/import .cube, apply to preview/recording, intensity.
/// A Popover, not a Menu — sliders don't work in an NSMenu (intensity "hung").
struct LUTMenu: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 12))
                if controller.settings.lutFileName != nil,
                   controller.lutPreviewOn || controller.lutRecordOn {
                    Circle()
                        .fill(controller.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            lutControls.padding(14).frame(width: 240)
        }
        .fixedSize()
        .help(L("lut_help"))
    }

    /// Name of the selected LUT for the menu title (or "No LUT").
    private var currentLUTName: String {
        controller.availableLUTs
            .first { $0.fileName == controller.settings.lutFileName }?.name
            ?? L("lut_none")
    }

    @ViewBuilder private var lutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("lut_help")).font(.caption).foregroundStyle(.secondary)
            // choosing and adding .cube in one dropdown menu (the separate import
            // button is gone: "Add .cube…" right in the list, multi-select)
            Menu {
                Button(L("lut_none")) { controller.selectLUT(fileName: nil) }
                if !controller.availableLUTs.isEmpty {
                    Divider()
                    ForEach(controller.availableLUTs) { lut in
                        Button(lut.name) { controller.selectLUT(fileName: lut.fileName) }
                    }
                }
                Divider()
                Button(L("lut_import")) { controller.importLUT() }
            } label: {
                HStack {
                    Text(currentLUTName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            Toggle(L("lut_preview"), isOn: Binding(
                get: { controller.lutPreviewOn },
                set: { controller.lutPreviewOn = $0 }))
            Toggle(L("lut_record"), isOn: Binding(
                get: { controller.lutRecordOn },
                set: { controller.lutRecordOn = $0 }))
            Divider()
            HStack(spacing: 6) {
                Text(L("lut_intensity_label")).font(.caption)
                Spacer()
                TextField("", value: Binding(
                    get: { Int((controller.lutIntensity * 100).rounded()) },
                    set: { controller.lutIntensity = Double(min(100, max(0, $0))) / 100 }),
                    format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 42)
                    .disabled(controller.settings.lutFileName == nil)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { controller.lutIntensity },
                set: { controller.lutIntensity = $0 }), in: 0...1)
            .disabled(controller.settings.lutFileName == nil)
        }
    }
}

/// Live/playback compare controls.
private struct CompareControls: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $controller.compareMode) {
                Text(L("compare_off")).tag(CaptureController.CompareMode.off)
                Text(L("compare_wipe")).tag(CaptureController.CompareMode.wipe)
                Text(L("compare_blend")).tag(CaptureController.CompareMode.blend)
                Text(L("compare_side")).tag(CaptureController.CompareMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .controlSize(.mini)

            if controller.compareMode == .wipe {
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
            if controller.compareMode == .blend {
                Slider(value: $controller.blendOpacity, in: 0...1)
                    .frame(width: 90)
                    .controlSize(.mini)
                TextField("", value: Binding(
                    get: { Int((controller.blendOpacity * 100).rounded()) },
                    set: { controller.blendOpacity = Double(min(100, max(0, $0))) / 100 }),
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
        .padding(4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Preview: live, playback, and compare modes.
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    /// The live signal's aspect — a shared compare container so frames of
    /// different resolutions (and the wipe) line up geometrically.
    static func liveAspect(_ format: CaptureFormat?) -> CGFloat {
        guard let format, format.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(format.width) / CGFloat(format.height)
    }

    /// Whether to show the transport (video playback, not a photo).
    private var showsTransport: Bool {
        guard controller.viewerMode == .playback, let url = controller.playbackURL
        else { return false }
        return !PlaybackContent.imageExtensions.contains(url.pathExtension.lowercased())
    }

    var body: some View {
        // the image area stays the same between record and playback: the transport
        // is a translucent bottom overlay, not a row that squeezes the frame
        ZStack(alignment: .bottom) {
            GeometryReader { _ in
                ZStack {
                    Rectangle().fill(controller.playerBackground)
                    if controller.viewerMode == .playback {
                        switch controller.compareMode {
                        case .off:
                            PlaybackContent()
                        case .blend:
                            ZStack {
                                LivePreviewContent()
                                PlaybackContent().opacity(controller.blendOpacity)
                            }
                            .aspectRatio(Self.liveAspect(controller.signalFormat),
                                         contentMode: .fit)
                        case .wipe:
                            ZStack {
                                LivePreviewContent()
                                PlaybackContent()
                                    .mask {
                                        WipeMask(orientation: controller.wipeOrientation,
                                                 position: controller.wipePosition)
                                    }
                                WipeHandle()
                            }
                            .aspectRatio(Self.liveAspect(controller.signalFormat),
                                         contentMode: .fit)
                        case .sideBySide:
                            HStack(spacing: 2) {
                                LivePreviewContent()
                                PlaybackContent()
                            }
                        }
                    } else if controller.multicamOn && !controller.extraChannels.isEmpty {
                        MulticamGrid()
                    } else {
                        LivePreviewContent()
                    }
                }
            }
            if showsTransport {
                TransportBar(player: controller.player)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if controller.isRecording, controller.viewerMode == .record {
                Label(L("rec"), systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }
}

/// Mask of the playback area for the wipe (left/top/diagonal from the line).
private struct WipeMask: Shape {
    let orientation: CaptureController.WipeOrientation
    let position: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch orientation {
        case .vertical:
            path.addRect(CGRect(x: 0, y: 0,
                                width: rect.width * position, height: rect.height))
        case .horizontal:
            path.addRect(CGRect(x: 0, y: 0,
                                width: rect.width, height: rect.height * position))
        case .diagonal:
            let t = position * (rect.width + rect.height)
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: t, y: 0))
            path.addLine(to: CGPoint(x: 0, y: t))
            path.closeSubpath()
        }
        return path
    }
}

/// Draggable compare wipe (line + handle, any direction).
private struct WipeHandle: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        GeometryReader { geo in
            let (p1, p2) = endpoints(in: geo.size)
            ZStack {
                Path { path in
                    path.move(to: p1)
                    path.addLine(to: p2)
                }
                .stroke(.white.opacity(0.9), lineWidth: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .position(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let size = geo.size
                let raw: Double
                switch controller.wipeOrientation {
                case .vertical:
                    raw = value.location.x / size.width
                case .horizontal:
                    raw = value.location.y / size.height
                case .diagonal:
                    raw = (value.location.x + value.location.y)
                        / (size.width + size.height)
                }
                controller.wipePosition = min(1, max(0, raw))
            })
        }
    }

    private func endpoints(in size: CGSize) -> (CGPoint, CGPoint) {
        switch controller.wipeOrientation {
        case .vertical:
            let x = size.width * controller.wipePosition
            return (CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height))
        case .horizontal:
            let y = size.height * controller.wipePosition
            return (CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y))
        case .diagonal:
            let t = controller.wipePosition * (size.width + size.height)
            let p1 = CGPoint(x: max(0, t - size.height), y: min(t, size.height))
            let p2 = CGPoint(x: min(t, size.width), y: max(0, t - size.width))
            return (p1, p2)
        }
    }
}

/// Preview grid of all cameras in multicam mode (main + extras).
struct MulticamGrid: View {
    @EnvironmentObject private var controller: CaptureController

    private var columns: Int {
        let n = 1 + controller.extraChannels.count
        return n <= 1 ? 1 : (n <= 4 ? 2 : 3)
    }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: columns)
        LazyVGrid(columns: cols, spacing: 4) {
            CameraTile(layer: controller.pipeline.displayLayer,
                       label: controller.settings.cameraLabel,
                       timecode: controller.currentTimecode,
                       recording: controller.isRecording,
                       background: controller.playerBackground)
            ForEach(controller.extraChannels) { channel in
                CameraTileChannel(channel: channel,
                                  background: controller.playerBackground)
            }
        }
        .padding(4)
    }
}

private struct CameraTileChannel: View {
    @ObservedObject var channel: CameraChannel
    let background: Color

    var body: some View {
        CameraTile(layer: channel.pipeline.displayLayer,
                   label: channel.camLabel,
                   timecode: channel.currentTimecode,
                   recording: channel.isRecording,
                   background: background)
    }
}

private struct CameraTile: View {
    let layer: AVSampleBufferDisplayLayer
    let label: String
    let timecode: Timecode?
    let recording: Bool
    let background: Color

    var body: some View {
        ZStack {
            Rectangle().fill(background)
            SampleLayerView(layer: layer)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(recording ? Color.red.opacity(0.9) : .white.opacity(0.12),
                          lineWidth: recording ? 2.5 : 1))
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            Text(timecode?.description ?? "--:--:--:--")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(recording ? .red : .white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }
}

/// AVSampleBufferDisplayLayer wrapper for the grid (module-public).
struct SampleLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Live signal + status badges.
struct LivePreviewContent: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            DisplayLayerView(layer: controller.pipeline.displayLayer)
            if !controller.isCapturing || controller.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 40))
                    Text(controller.backendAvailable
                         ? L("no_devices_found")
                         : L("sdk_not_connected"))
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
            } else if !controller.signalPresent {
                Text(L("no_signal"))
                    .font(.headline)
                    .padding(8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// NSView wrapper around AVSampleBufferDisplayLayer.
private struct DisplayLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Footer: utilities on the left, meters centered in the left half, REC in the
/// center, naming fields on the right.
struct BottomBarView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        HStack(spacing: 10) {
                            SettingsLink {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 15))
                            }
                            .help(L("open_settings"))

                            Button {
                                openWindow(id: "vanc-monitor")
                            } label: {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 15))
                            }
                            .help(L("vanc_open_help"))

                            NamingPresetMenu()

                            Button {
                                controller.toggleMulticam()
                            } label: {
                                Image(systemName: controller.multicamOn
                                      ? "rectangle.split.2x1.fill"
                                      : "rectangle.split.2x1")
                                    .font(.system(size: 15))
                                    .foregroundStyle(controller.multicamOn
                                                     ? controller.accentColor : .primary)
                            }
                            .help(L("multicam_toggle"))

                            Button {
                                controller.grabFrame()
                            } label: {
                                Image(systemName: "camera")
                                    .font(.system(size: 15))
                            }
                            .disabled(!controller.isCapturing && controller.playbackURL == nil)
                            .help(L("grab_frame"))

                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    controller.showScopes.toggle()
                                }
                            } label: {
                                Image(systemName: "waveform.path.ecg.rectangle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(controller.showScopes
                                                     ? controller.accentColor : .primary)
                            }
                            .help(L("scopes_toggle"))
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)

                        if controller.isCapturing, !controller.audioLevels.isEmpty {
                            Button {
                                controller.showAudioPanel.toggle()
                            } label: {
                                AudioMeterView(
                                    levels: controller.audioLevels,
                                    enabled: (0..<controller.audioLevels.count)
                                        .map { controller.isChannelEnabled($0) })
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .help(L("meters_click_help"))
                        }

                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: .infinity)

                    NamingFieldsView()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RecordButton()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Naming-style picker right from the footer (same presets as in Settings).
struct NamingPresetMenu: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Menu {
            ForEach(SettingsView.namingPresets, id: \.key) { preset in
                Button {
                    controller.applyNamingPreset(preset)
                } label: {
                    if controller.settings.namingTemplate == preset.template {
                        Label(L(preset.key), systemImage: "checkmark")
                    } else {
                        Text(L(preset.key))
                    }
                }
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("naming_preset"))
    }
}

/// QuickTime-style record button.
struct RecordButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        Button {
            controller.toggleManualRecord()
        } label: {
            // like QuickTime: a light-grey disc; a red circle means ready to record,
            // a white square means recording
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 48, height: 48)
                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
                        .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!controller.isCapturing)
        .help("\(controller.isRecording ? L("stop") : L("record")) — \(hotkeys.combo(for: .toggleRecord).display)")
        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
    }
}

/// CLIP field: digits only, max 4; text isn't reformatted while typing,
/// commit on Enter/blur; leading zeros set the filename padding.
struct ClipField: View {
    @EnvironmentObject private var controller: CaptureController
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("clip_label"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            HStack(spacing: 1) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 50)
                    .focused($focused)
                    .onSubmit { controller.commitClipText(text) }
                Stepper("", onIncrement: {
                    controller.nextTakeNumber = min(9999, controller.nextTakeNumber + 1)
                }, onDecrement: {
                    controller.nextTakeNumber = max(0, controller.nextTakeNumber - 1)
                })
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .fixedSize()
        .onAppear { text = controller.clipDisplay }
        .onChange(of: text) { _, newValue in
            // digits only, no more than four
            let filtered = String(newValue.filter(\.isNumber).prefix(4))
            if filtered != newValue { text = filtered }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { controller.commitClipText(text) }
        }
        .onChange(of: controller.nextTakeNumber) { _, _ in
            if !focused { text = controller.clipDisplay }
        }
        .onChange(of: controller.settings.clipPadWidth) { _, _ in
            if !focused { text = controller.clipDisplay }
        }
    }
}

/// Naming fields: compact, labels above the fields on the left.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // warning: the current name is already taken in the folder
            if let collision = controller.nameCollision {
                VStack(spacing: 1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("name_taken_short"))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 8)
                .help(L("name_taken_help", collision))
                .transition(.opacity)
            }
            // show only the fields that actually exist in the current template
            if uses("{cam}") {
                steppedField(L("cam_label"), width: 40,
                             text: $controller.settings.cameraLabel,
                             onStep: { controller.stepCamera($0) })
            }
            if uses("{roll}") {
                steppedField(L("roll_label"), width: 50,
                             text: $controller.roll,
                             onStep: { controller.stepRoll($0) })
            }
            if uses("{clip}") {
                ClipField()
                    .help(L("clip_help"))
            }
            if uses("{postfix}") {
                labeledField(L("postfix_label"), width: 56) {
                    TextField("", text: Binding(
                        get: { controller.settings.postfix ?? "" },
                        set: { controller.settings.postfix = $0.isEmpty ? nil : $0 }))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.nameCollision)
        .animation(.easeOut(duration: 0.15), value: controller.settings.namingTemplate)
    }

    /// Whether a placeholder is in the current template.
    private func uses(_ placeholder: String) -> Bool {
        controller.settings.namingTemplate.contains(placeholder)
    }

    private func labeledField(_ label: String, width: CGFloat,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .fixedSize()
    }

    private func steppedField(_ label: String, width: CGFloat,
                              text: Binding<String>,
                              onStep: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 2)
            HStack(spacing: 1) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: width)
                Stepper("", onIncrement: { onStep(1) }, onDecrement: { onStep(-1) })
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .fixedSize()
    }
}
