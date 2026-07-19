import AVFoundation
import AVKit
import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TopBarView()
                // плеер — обособленная карточка; подвал ПОД ней, ничего не перекрывает
                PreviewView()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.08)))
                    .padding(.horizontal, 12)
                BottomBarView()
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.08)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minWidth: 660)

            TakeListView()
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.07)))
                .padding(8)
                .frame(minWidth: 300, maxWidth: 420)
        }
        .background(controller.appBackground.ignoresSafeArea())
    }
}

/// Строка над плеером: слева таймкод, справа разрешение и fps.
struct TopBarView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // три колонки: TC прижат к левому краю, переключатель ровно по центру
        // плеера, инфо о сигнале — к правому. Кнопки окна живут строкой выше
        // (отступ сверху), поэтому края свободны.
        HStack(spacing: 8) {
            Text(controller.currentTimecode?.description ?? "--:--:--:--")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(controller.isRecording ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $controller.viewerMode) {
                Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
                Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .labelsHidden()
            .controlSize(.small)

            Group {
                if let format = controller.signalFormat {
                    Text(Self.shortFormat(format))
                        .monospacedDigit()
                } else {
                    Text(L("no_signal_short"))
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18) // впритык к кнопкам окна
        .padding(.bottom, 6)
    }

    static func fpsText(_ fps: Double) -> String {
        fps.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(fps))
            : String(format: "%.2f", fps)
    }

    /// Короткое обозначение: "1080p25", "2160p23.98".
    static func shortFormat(_ format: CaptureFormat) -> String {
        "\(format.height)p\(fpsText(format.frameRate))"
    }
}

/// Живое превью входного сигнала.
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Rectangle().fill(controller.playerBackground)
            if controller.viewerMode == .playback {
                PlaybackView()
            } else {
                LivePreviewContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if controller.isRecording {
                Label(L("rec"), systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }
}

/// Живой сигнал + плашки состояний (вынесено из PreviewView).
private struct LivePreviewContent: View {
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

/// Нижняя панель: утилиты слева (как в Resolve), REC строго по центру,
/// поля нейминга справа.
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
            // левая колонка — настройки и сервис
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
            // REC — в геометрическом центре панели, метры слева от него
            ZStack {
                RecordButton()
                if controller.isCapturing, !controller.audioLevels.isEmpty {
                    AudioMeterView(levels: controller.audioLevels)
                        .frame(height: 46)
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
        let metersWidth = CGFloat(channels) * 7 + 8
        return metersWidth / 2 + 14 + 26
    }
}

/// Большая явная кнопка записи — по центру под плеером.
struct RecordButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        Button {
            controller.toggleManualRecord()
        } label: {
            // как в QuickTime: красный кружок в кольце — готов писать,
            // чёрный квадратик — идёт запись (нажми, чтобы остановить)
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

/// Поля нейминга: Prefix, Cam, Roll, Clip, Postfix.
/// Подписи по центру; Cam/Roll/Clip — со степперами, Clip редактируется руками.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            labeledField(L("prefix_label"), width: 100) {
                TextField("", text: $controller.settings.projectName,
                          prompt: Text(L("prefix_prompt")))
            }
            steppedField(L("cam_label"), width: 40,
                         text: $controller.settings.cameraLabel,
                         onStep: { controller.stepCamera($0) })
            steppedField(L("roll_label"), width: 52,
                         text: $controller.roll,
                         onStep: { controller.stepRoll($0) })
            steppedField(L("clip_label"), width: 40,
                         text: Binding(
                            get: { String(format: "%02d", controller.nextTakeNumber) },
                            set: { controller.nextTakeNumber = max(0, min(999, Int($0) ?? controller.nextTakeNumber)) }),
                         onStep: { controller.nextTakeNumber = max(0, min(999, controller.nextTakeNumber + $0)) })
                .help(L("clip_help"))
            labeledField(L("postfix_label"), width: 70) {
                TextField("", text: Binding(
                    get: { controller.settings.postfix ?? "" },
                    set: { controller.settings.postfix = $0.isEmpty ? nil : $0 }))
            }
        }
    }

    private func labeledField(_ label: String, width: CGFloat,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            content()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: width)
        }
        .fixedSize()
    }

    private func steppedField(_ label: String, width: CGFloat,
                              text: Binding<String>,
                              onStep: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            HStack(spacing: 2) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
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
