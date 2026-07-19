import AVFoundation
import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: CaptureController
    @AppStorage("panelSide") private var panelSide = "right"

    var body: some View {
        HSplitView {
            if panelSide == "left" && !controller.isImmersive {
                sidePanel
            }
            mainColumn
            if panelSide == "right" && !controller.isImmersive {
                sidePanel
            }
        }
        .background(controller.appBackground.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        // клик по пустому месту снимает фокус с текстовых полей
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if !controller.isImmersive {
                // полоса под кнопки окна (за неё же таскается окно)
                Color.clear.frame(height: 26)
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
        .frame(minWidth: 600, maxWidth: .infinity)
    }

    private var sidePanel: some View {
        TakeListView()
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.07)))
            // верхняя кромка вровень с плеером (у него полоса 26 под кнопки окна)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .padding(.horizontal, 10)
            .frame(minWidth: 310, maxWidth: 560)
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
                                .font(.body)
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
                .overlay {
                    if controller.showAudioPanel {
                        AudioChannelPanel()
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
            .fixedSize()
            .labelsHidden()
            .controlSize(.mini)

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
                    .frame(width: 38)
                    .controlSize(.mini)
                Text("%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                            Button {
                                controller.chooseDestinationFolder()
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 15))
                            }
                            .help(L("choose_folder"))
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)

                        // метры — по центру между утилитами и REC
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
            // как в QuickTime: светло-серый диск; красный кружок — готов писать,
            // белый квадратик — идёт запись
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

/// Поля нейминга: компактные, подписи слева над полями.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            steppedField(L("cam_label"), width: 28,
                         text: $controller.settings.cameraLabel,
                         onStep: { controller.stepCamera($0) })
            steppedField(L("roll_label"), width: 58,
                         text: $controller.roll,
                         onStep: { controller.stepRoll($0) })
            steppedField(L("clip_label"), width: 46,
                         text: Binding(
                            get: { String(format: "%02d", controller.nextTakeNumber) },
                            set: { controller.nextTakeNumber = max(0, min(9999, Int($0) ?? controller.nextTakeNumber)) }),
                         onStep: { controller.nextTakeNumber = max(0, min(9999, controller.nextTakeNumber + $0)) })
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
