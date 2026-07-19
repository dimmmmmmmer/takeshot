import AVFoundation
import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if !controller.isImmersive {
                    // тонкая полоса под кнопки окна (и за неё можно таскать окно)
                    Color.clear.frame(height: 24)
                }
                PlayerArea()
                if !controller.isImmersive {
                    BottomBarView()
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.08)))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .frame(minWidth: 700)

            if !controller.isImmersive {
                TakeListView()
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.07)))
                    .padding(8)
                    .frame(minWidth: 300, maxWidth: 420)
            }
        }
        .background(controller.appBackground.ignoresSafeArea())
    }
}

/// Плеер-карточка: TC, формат и переключатель режима живут прямо на ней.
/// В иммерсиве занимает всё окно, подвал выезжает по ховеру снизу.
struct PlayerArea: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var footerHover = false

    var body: some View {
        GeometryReader { geo in
            PreviewView()
                .clipShape(RoundedRectangle(cornerRadius: controller.isImmersive ? 0 : 14))
                .overlay(RoundedRectangle(cornerRadius: controller.isImmersive ? 0 : 14)
                    .strokeBorder(.white.opacity(controller.isImmersive ? 0 : 0.08)))
                .overlay(alignment: .topLeading) {
                    if !controller.isImmersive {
                        overlayBadge {
                            Text(controller.currentTimecode?.description ?? "--:--:--:--")
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(controller.isRecording ? .red : .primary)
                        }
                        .padding(8)
                    }
                }
                .overlay(alignment: .top) {
                    if !controller.isImmersive {
                        VStack(spacing: 4) {
                            Picker("", selection: $controller.viewerMode) {
                                Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
                                Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 190)
                            .labelsHidden()
                            .controlSize(.small)

                            if controller.viewerMode == .playback {
                                CompareControls()
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !controller.isImmersive {
                        overlayBadge {
                            HStack(spacing: 8) {
                                Group {
                                    if let format = controller.signalFormat {
                                        Text(Self.shortFormat(format)).monospacedDigit()
                                    } else {
                                        Text(L("no_signal_short"))
                                    }
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                Button {
                                    controller.toggleFullscreen()
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .help(L("fullscreen"))
                            }
                        }
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if controller.isImmersive && footerHover {
                        BottomBarView()
                            .background(.ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 18))
                            .padding(.horizontal, 40)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onContinuousHover { phase in
                    guard controller.isImmersive else { return }
                    switch phase {
                    case .active(let point):
                        withAnimation(.easeOut(duration: 0.15)) {
                            footerHover = point.y > geo.size.height - 140
                        }
                    case .ended:
                        withAnimation(.easeOut(duration: 0.15)) { footerHover = false }
                    }
                }
        }
        .padding(.horizontal, controller.isImmersive ? 0 : 12)
    }

    private func overlayBadge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
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

/// Управление сравнением лайв/плейбек.
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
            .frame(width: 250)
            .labelsHidden()
            .controlSize(.mini)

            if controller.compareMode == .blend {
                Slider(value: $controller.blendOpacity, in: 0...1)
                    .frame(width: 90)
                    .controlSize(.mini)
            }
        }
        .padding(4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Превью: лайв, плейбек и режимы сравнения.
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Rectangle().fill(controller.playerBackground)
                    if controller.viewerMode == .playback {
                        switch controller.compareMode {
                        case .off:
                            PlaybackContent()
                        case .blend:
                            LivePreviewContent()
                            PlaybackContent().opacity(controller.blendOpacity)
                        case .wipe:
                            LivePreviewContent()
                            PlaybackContent()
                                .mask(alignment: .leading) {
                                    Rectangle().frame(
                                        width: geo.size.width * controller.wipePosition)
                                }
                            WipeHandle()
                        case .sideBySide:
                            HStack(spacing: 2) {
                                LivePreviewContent()
                                PlaybackContent()
                            }
                        }
                    } else {
                        LivePreviewContent()
                    }
                }
            }
            if controller.viewerMode == .playback, let url = controller.playbackURL,
               !PlaybackContent.imageExtensions.contains(url.pathExtension.lowercased()) {
                TransportBar(player: controller.player)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if controller.isRecording {
                Label(L("rec"), systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }
}

/// Перетаскиваемая шторка сравнения.
private struct WipeHandle: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2)
                .overlay {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                }
                .position(x: geo.size.width * controller.wipePosition,
                          y: geo.size.height / 2)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    controller.wipePosition =
                        min(1, max(0, value.location.x / geo.size.width))
                })
        }
    }
}

/// Живой сигнал + плашки состояний.
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

/// NSView-обёртка вокруг AVSampleBufferDisplayLayer.
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

/// Подвал: утилиты слева, REC по центру, поля нейминга справа.
struct BottomBarView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            ZStack {
                HStack(spacing: 8) {
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

                        Button {
                            controller.chooseDestinationFolder()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 15))
                        }
                        .help(L("choose_folder"))
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    NamingFieldsView()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                // REC — в геометрическом центре, метры слева от него
                ZStack {
                    RecordButton()
                    if controller.isCapturing, !controller.audioLevels.isEmpty {
                        AudioMeterView(levels: controller.audioLevels)
                            .frame(height: 44)
                            .offset(x: -Self.meterOffset(for: controller.audioLevels.count))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Смещение метров влево от центра: половина ширины метров + зазор + радиус кнопки.
    static func meterOffset(for channels: Int) -> CGFloat {
        let metersWidth = CGFloat(channels) * 5 + 8
        return metersWidth / 2 + 12 + 26
    }
}

/// Кнопка записи в стиле QuickTime.
struct RecordButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        Button {
            controller.toggleManualRecord()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 3)
                    .frame(width: 52, height: 52)
                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black)
                        .frame(width: 22, height: 22)
                        .shadow(color: .red.opacity(0.6), radius: 8)
                } else {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.33, blue: 0.27),
                                     Color(red: 0.82, green: 0.11, blue: 0.08)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 40, height: 40)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!controller.isCapturing)
        .help("\(controller.isRecording ? L("stop") : L("record")) — \(hotkeys.combo(for: .toggleRecord).display)")
        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
    }
}

/// Поля нейминга: компактные, подписи слева над полями.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            labeledField(L("prefix_label"), width: 72) {
                TextField("", text: $controller.settings.projectName,
                          prompt: Text(L("prefix_prompt")))
            }
            steppedField(L("cam_label"), width: 28,
                         text: $controller.settings.cameraLabel,
                         onStep: { controller.stepCamera($0) })
            steppedField(L("roll_label"), width: 40,
                         text: $controller.roll,
                         onStep: { controller.stepRoll($0) })
            steppedField(L("clip_label"), width: 32,
                         text: Binding(
                            get: { String(format: "%02d", controller.nextTakeNumber) },
                            set: { controller.nextTakeNumber = max(0, min(999, Int($0) ?? controller.nextTakeNumber)) }),
                         onStep: { controller.nextTakeNumber = max(0, min(999, controller.nextTakeNumber + $0)) })
                .help(L("clip_help"))
            labeledField(L("postfix_label"), width: 56) {
                TextField("", text: Binding(
                    get: { controller.settings.postfix ?? "" },
                    set: { controller.settings.postfix = $0.isEmpty ? nil : $0 }))
            }
        }
    }

    private func labeledField(_ label: String, width: CGFloat,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            content()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
        .fixedSize()
    }

    private func steppedField(_ label: String, width: CGFloat,
                              text: Binding<String>,
                              onStep: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
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
