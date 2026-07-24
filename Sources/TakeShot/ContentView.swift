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

/// TC readout that updates every frame — isolated so only this text
/// re-renders at frame rate (see LiveSignal).
private struct LiveTimecodeText: View {
    @ObservedObject var live: LiveSignal
    let tint: Color

    var body: some View {
        Text(live.currentTimecode?.description ?? "--:--:--:--")
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 96, alignment: .leading)
    }
}

/// Playback position as timecode: file start TC + player time, at the file's fps.
private struct PlaybackTimecodeText: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(controller.playbackTimecodeText)
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 96, alignment: .leading)
            .onReceive(timer) { date in now = date } // re-render tick
    }
}

/// Player card: TC, format, and the mode switch live right on it.
struct PlayerArea: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.openWindow) private var openWindow

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
                    Menu {
                        Picker(L("detection_mode"),
                               selection: $controller.settings.detectionMode) {
                            Text(L("mode_vanc")).tag(RecDetectionMode.vanc)
                            Text(L("mode_auto")).tag(RecDetectionMode.auto)
                            Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
                            Text(L("mode_manual")).tag(RecDetectionMode.manual)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        if controller.viewerMode == .playback {
                            PlaybackTimecodeText()
                        } else {
                            LiveTimecodeText(
                                live: controller.live,
                                tint: controller.isRecording ? Color.red : Color.white)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("tc_menu_help"))
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

                    if (controller.viewerMode == .playback
                        && controller.playbackURL != nil)
                        || (controller.viewerMode == .record
                            && controller.referencePinned) {
                        CompareControls()
                    }
                }
                .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    overlayBadge {
                        Button {
                            controller.showScopesOverlay.toggle()
                        } label: {
                            Image(systemName: "waveform.path.ecg.rectangle")
                                .font(.system(size: 13))
                                .foregroundStyle(controller.showScopes
                                                 ? controller.accentColor : .white)
                        }
                        .buttonStyle(.plain)
                        .help(L("scopes_toggle"))
                    }
                    overlayBadge {
                        LUTMenu()
                    }
                    overlayBadge {
                        Menu {
                            Picker(L("input_mode"), selection: Binding(
                                get: { controller.settings.forcedInputMode ?? "auto" },
                                set: { controller.settings.forcedInputMode =
                                    $0 == "auto" ? nil : $0 })) {
                                Text(L("input_mode_auto")).tag("auto")
                                ForEach(controller.selectedDeviceInputModes,
                                        id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                            if controller.settings.forcedInputMode != nil {
                                Toggle(L("input_mode_rgb"), isOn: Binding(
                                    get: { controller.settings.forcedInputRGB ?? false },
                                    set: { controller.settings.forcedInputRGB = $0 }))
                            }
                        } label: {
                            Group {
                                if controller.viewerMode == .playback,
                                   let info = controller.playbackFormatText {
                                    Text(info).monospacedDigit()
                                } else if let format = controller.signalFormat {
                                    Text(Self.shortFormat(format)).monospacedDigit()
                                } else {
                                    Text(L("no_signal_short"))
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(L("input_mode"))
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
                    AudioChannelPanel(live: controller.live)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if controller.showScopesOverlay, !controller.scopesWindowOpen {
                    ScopesPanel(live: controller.live)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.12)))
                        .frame(maxWidth: 860, maxHeight: 320)
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
                } else if let notice = controller.lastNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.green)
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
            .animation(.easeOut(duration: 0.2), value: controller.lastNotice)
            .padding(.horizontal, 12)
    }

    private func overlayBadge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .foregroundStyle(.white) // readable on any player background (incl. black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
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
            // same footprint as the neighbouring badge icons; the active-LUT
            // dot sits on the icon's corner instead of reserving width
            Image(systemName: "camera.filters")
                .font(.system(size: 13))
                .overlay(alignment: .topTrailing) {
                    if controller.settings.lutFileName != nil,
                       controller.lutPreviewOn || controller.lutRecordOn {
                        Circle()
                            .fill(controller.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
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
                Button {
                    controller.selectLUT(fileName: nil)
                } label: {
                    if controller.settings.lutFileName == nil {
                        Label(L("lut_none"), systemImage: "checkmark")
                    } else {
                        Text(L("lut_none"))
                    }
                }
                if !controller.availableLUTs.isEmpty {
                    Divider()
                    ForEach(controller.availableLUTs) { lut in
                        Button {
                            controller.selectLUT(fileName: lut.fileName)
                        } label: {
                            if controller.settings.lutFileName == lut.fileName {
                                Label(lut.name, systemImage: "checkmark")
                            } else {
                                Text(lut.name)
                            }
                        }
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
            Button {
                controller.pinReferenceFromCurrentFrame()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(L("pin_reference_help"))
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

    /// Photos keep the SwiftUI graphics path (Image is color-managed correctly,
    /// and compare masks/opacity over Image views don't shift color).
    @ViewBuilder private var imagePlaybackBranch: some View {
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
    }

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
        let ext = url.pathExtension.lowercased()
        return !PlaybackContent.imageExtensions.contains(ext)
            && !CaptureController.rawExtensions.contains(ext)
    }

    /// RAW clips get the engine's own transport.
    private var showsRawTransport: Bool {
        guard controller.viewerMode == .playback, let url = controller.playbackURL
        else { return false }
        return CaptureController.rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the playback file is a photo.
    private var isImage: Bool {
        controller.playbackURL.map {
            PlaybackContent.imageExtensions.contains($0.pathExtension.lowercased())
        } ?? false
    }

    /// What feeds the unified surface right now.
    private var surfaceSource: ViewerSurface.Source {
        if controller.viewerMode == .record { return .live }
        guard let url = controller.playbackURL else { return .none }
        let ext = url.pathExtension.lowercased()
        if PlaybackContent.imageExtensions.contains(ext) { return .none }
        if CaptureController.rawExtensions.contains(ext) {
            if let raw = controller.rawPlayer {
                return .raw(ObjectIdentifier(raw))
            }
            return .none
        }
        return .playback
    }

    var body: some View {
        // the image area stays the same between record and playback: the transport
        // is a translucent bottom overlay, not a row that squeezes the frame
        ZStack(alignment: .bottom) {
            GeometryReader { _ in
                ZStack {
                    Rectangle().fill(controller.playerBackground)
                    if controller.viewerMode == .record, controller.multicamOn,
                       !controller.extraChannels.isEmpty {
                        MulticamGrid()
                    } else if controller.viewerMode == .playback, isImage {
                        imagePlaybackBranch
                    } else if controller.viewerMode == .playback,
                              controller.compareMode == .sideBySide,
                              controller.playbackURL != nil {
                        HStack(spacing: 2) {
                            LivePreviewContent()
                            PlaybackContent()
                        }
                    } else {
                        // ONE NSView/layer for live, playback video and RAW: the
                        // mode switch re-routes frames into the same surface, so
                        // rec и playback land on identical pixels by construction
                        ViewerSurface(controller: controller, source: surfaceSource)
                        if controller.viewerMode == .record {
                            LiveStatusOverlay()
                        } else if controller.playbackURL == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 40))
                                Text(L("playback_pick_hint"))
                                    .font(.headline)
                            }
                            .foregroundStyle(.secondary)
                        } else if case .none = surfaceSource {
                            // RAW that failed to open
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 32))
                                Text(controller.rawPlayerError ?? L("raw_open_failed"))
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.secondary)
                            .padding(20)
                        }
                        // the wipe seam/handle rides the same centered aspect-fit
                        // box the layer letterboxes the composite into
                        if controller.compareMode == .wipe,
                           (controller.viewerMode == .playback
                            && controller.playbackURL != nil)
                            || (controller.viewerMode == .record
                                && controller.referencePinned) {
                            Color.clear
                                .aspectRatio(
                                    controller.viewerMode == .playback
                                        ? (controller.playbackAspect
                                           ?? Self.liveAspect(controller.signalFormat))
                                        : Self.liveAspect(controller.signalFormat),
                                    contentMode: .fit)
                                .overlay { WipeHandle() }
                        }
                    }
                }
            }
            if showsTransport {
                TransportBar(player: controller.player)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            } else if showsRawTransport, let model = controller.rawPlayer {
                RawTransportBar(model: model)
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

/// Mask of the playback area for the wipe (left/top/diagonal from the line) —
/// used for still images, which render on the color-correct graphics path.
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
            MainCameraTile(live: controller.live)
            ForEach(controller.extraChannels) { channel in
                CameraTileChannel(channel: channel,
                                  background: controller.playerBackground)
            }
        }
        .padding(4)
    }
}

/// Main-camera tile: observes LiveSignal for TC so only the tile re-renders.
private struct MainCameraTile: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

    var body: some View {
        CameraTile(pipeline: controller.pipeline,
                   label: controller.settings.cameraLabel,
                   timecode: live.currentTimecode,
                   recording: controller.isRecording,
                   background: controller.playerBackground)
    }
}

private struct CameraTileChannel: View {
    @ObservedObject var channel: CameraChannel
    let background: Color

    var body: some View {
        CameraTile(pipeline: channel.pipeline,
                   label: channel.camLabel,
                   timecode: channel.currentTimecode,
                   recording: channel.isRecording,
                   background: background)
    }
}

private struct CameraTile: View {
    let pipeline: CapturePipeline
    let label: String
    let timecode: Timecode?
    let recording: Bool
    let background: Color

    var body: some View {
        ZStack {
            Rectangle().fill(background)
            LivePreviewLayerView(pipeline: pipeline)
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

/// Live signal + status badges.
struct LivePreviewContent: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            LivePreviewLayerView(pipeline: controller.pipeline)
            LiveStatusOverlay()
        }
    }
}

/// Status text over the live image (no devices / no signal).
struct LiveStatusOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
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
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// The main viewer surface: one NSView + one MetalPreviewLayer whose frame
/// source is re-routed between live capture, AVPlayer playback and the RAW
/// engine. One surface — rec and playback occupy identical pixels, so a mode
/// switch cannot shift or resize the image.
struct ViewerSurface: NSViewRepresentable {
    let controller: CaptureController
    let source: Source

    enum Source: Equatable {
        case none
        case live
        case playback
        case raw(ObjectIdentifier)
    }

    final class Coordinator {
        var layer: MetalPreviewLayer?
        weak var pipeline: CapturePipeline?
        weak var tap: PlaybackFrameTap?
        weak var raw: RawPlayerModel?
        var current: Source = .none
        var attached = false

        @MainActor
        func attach(_ source: Source, controller: CaptureController) {
            guard let layer, !attached || source != current else { return }
            detach()
            attached = true
            current = source
            switch source {
            case .none:
                layer.clearToBlack()
            case .live:
                pipeline = controller.pipeline
                controller.pipeline.addDisplaySink(layer)
            case .playback:
                tap = controller.playbackTap
                controller.playbackTap.addSink(layer)
            case .raw:
                raw = controller.rawPlayer
                controller.rawPlayer?.addSink(layer)
            }
        }

        @MainActor
        func detach() {
            guard let layer else { return }
            pipeline?.removeDisplaySink(layer)
            tap?.removeSink(layer)
            raw?.removeSink(layer)
            pipeline = nil
            tap = nil
            raw = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        context.coordinator.layer = layer
        context.coordinator.attach(source, controller: controller)
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(source, controller: controller)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

/// Live preview mount: creates its OWN layer and registers it as a pipeline
/// sink (a CALayer can live in one view only — the pipeline mirrors frames to
/// every registered sink, so compare/multicam mounts don't fight over one).
struct LivePreviewLayerView: NSViewRepresentable {
    let pipeline: CapturePipeline

    final class Coordinator {
        var pipeline: CapturePipeline?
        var layer: MetalPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        pipeline.addDisplaySink(layer)
        context.coordinator.pipeline = pipeline
        context.coordinator.layer = layer
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.pipeline?.removeDisplaySink(layer)
        }
    }
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
                            Button {
                                openWindow(id: "settings")
                            } label: {
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

                            FooterMonitorButton(live: controller.live)

                            Button {
                                controller.instantReplay()
                            } label: {
                                Image(systemName: "memories")
                                    .font(.system(size: 15))
                            }
                            .disabled(controller.takes.isEmpty)
                            .help("\(L("instant_replay_help")) — \(hotkeys.combo(for: .instantReplay).display)")
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)

                        if controller.isCapturing {
                            FooterAudioMeters(live: controller.live)
                        }

                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: .infinity)

                    NamingFieldsView()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                RecordButton()
                    .overlay(alignment: .center) {
                        Button {
                            controller.grabFrame()
                        } label: {
                            Image(systemName: "camera")
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.borderless)
                        .disabled(!controller.isCapturing && controller.playbackURL == nil)
                        .help(L("grab_frame"))
                        .offset(x: 52)
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Footer speaker: volume popover. In record mode it drives the live monitor,
/// in playback — the player volume (the transport has no volume of its own).
private struct FooterMonitorButton: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject private var live: LiveSignal
    @State private var showPopover = false

    init(live: LiveSignal) {
        self.live = live
    }

    private var isPlayback: Bool { controller.viewerMode == .playback }

    private var volume: Binding<Double> {
        Binding(get: { controller.monitorVolume },
                set: { controller.monitorVolume = $0 })
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: isPlayback
                  ? (live.volume == 0
                     ? "speaker.slash.fill" : "speaker.wave.2.fill")
                  : (controller.monitorOn
                     ? (live.volume == 0
                        ? "speaker.slash.fill" : "speaker.wave.2.fill")
                     : "speaker.slash"))
                .font(.system(size: 15))
                .foregroundStyle((isPlayback ? live.volume > 0
                                             : controller.monitorOn)
                                 ? controller.accentColor : .primary)
                // fixed BOTH dimensions: the symbol variants differ in size and
                // a changing anchor makes the volume popover jump around
                .frame(width: 24, height: 20)
        }
        .disabled(!isPlayback && !controller.isCapturing)
        .help(L("monitor_toggle"))
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(spacing: 10) {
                TextField("", value: Binding(
                    get: { Int((volume.wrappedValue * 100).rounded()) },
                    set: { volume.wrappedValue = Double(min(100, max(0, $0))) / 100 }),
                    format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                Slider(value: volume, in: 0...1)
                    .frame(width: 100)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 28, height: 108)
            }
            .padding(12)
        }
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
                // camera labels are plain uppercase latin (A, B, C…): anything
                // else lands in file names on other people's systems
                steppedField(L("cam_label"), width: 40,
                             text: Binding(
                                 get: { controller.settings.cameraLabel },
                                 set: { controller.settings.cameraLabel =
                                     Self.camSanitized($0) }),
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

    static func camSanitized(_ value: String) -> String {
        String(value.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) })
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

/// Footer audio meters — observe LiveSignal so the ~25/s level updates
/// re-render only this small view, not the whole footer.
private struct FooterAudioMeters: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !live.audioLevels.isEmpty {
            Button {
                controller.showAudioPanel.toggle()
            } label: {
                AudioMeterView(
                    levels: live.audioLevels,
                    enabled: (0..<live.audioLevels.count)
                        .map { controller.isChannelEnabled($0) })
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .help(L("meters_click_help"))
        }
    }
}
