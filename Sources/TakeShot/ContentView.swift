import AVFoundation
import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TopBarView()
                PreviewView()
                BottomBarView()
            }
            .frame(minWidth: 620)

            TakeListView()
                .frame(minWidth: 280, maxWidth: 400)
        }
    }
}

/// Строка над плеером: слева таймкод, справа разрешение и fps.
struct TopBarView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(controller.currentTimecode?.description ?? "--:--:--:--")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(controller.isRecording ? .red : .primary)

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.leading, 12)
            }

            Spacer()

            if let format = controller.signalFormat {
                Text(Self.shortFormat(format))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(L("no_signal_short"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        // отступ слева под маковские кнопки окна (титлбар скрыт, они поверх контента)
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
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

                if controller.isMockSelected && controller.isCapturing {
                    Button {
                        controller.toggleMockCameraRecord()
                    } label: {
                        Image(systemName: controller.mockCameraRecording
                              ? "video.fill" : "video")
                            .font(.system(size: 15))
                            .foregroundStyle(controller.mockCameraRecording ? .red : .primary)
                    }
                    .help(controller.mockCameraRecording ? L("mock_rec_stop") : L("mock_rec"))
                }
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)

            RecordButton()

            NamingFieldsView()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            ZStack {
                Circle()
                    .fill(controller.isRecording
                          ? Color.red
                          : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 52, height: 52)
                    .shadow(color: controller.isRecording ? .red.opacity(0.7) : .clear,
                            radius: 9)
                Circle()
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 52, height: 52)
                Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(controller.isRecording ? .white : .red)
            }
        }
        .buttonStyle(.plain)
        .disabled(!controller.isCapturing)
        .help("\(controller.isRecording ? L("stop") : L("record")) — \(hotkeys.combo(for: .toggleRecord).display)")
        .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
    }
}

/// Поля нейминга: Prefix (имя проекта), Cam, Roll, Clip.
struct NamingFieldsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            labeledField(L("prefix_label"), width: 110) {
                TextField("", text: $controller.settings.projectName,
                          prompt: Text(L("prefix_prompt")))
            }
            labeledField(L("cam_label"), width: 44) {
                TextField("", text: $controller.settings.cameraLabel)
            }
            labeledField(L("roll_label"), width: 64) {
                TextField("", text: $controller.roll)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L("clip_label"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Stepper(String(format: "%02d", controller.nextTakeNumber),
                        value: $controller.nextTakeNumber, in: 0...999)
                    .controlSize(.small)
                    .monospacedDigit()
            }
            .help(L("clip_help"))
        }
    }

    private func labeledField(_ label: String, width: CGFloat,
                              @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
