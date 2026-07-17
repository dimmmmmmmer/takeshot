import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewView()
                StatusBarView()
                Divider()
                ControlsView()
            }
            .frame(minWidth: 600)

            TakeListView()
                .frame(minWidth: 280, maxWidth: 400)
        }
    }
}

/// Превью входного сигнала. До этапа 3 — плейсхолдер.
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            if !controller.backendAvailable {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 40))
                    Text("DeckLink SDK не подключён")
                        .font(.headline)
                    Text("Положите заголовки SDK в vendor/DeckLinkSDK/include и пересоберите")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else if !controller.isCapturing {
                Text("Захват не запущен")
                    .foregroundStyle(.secondary)
            } else if controller.signalFormat == nil {
                Text("Нет сигнала")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if controller.isRecording {
                Label("REC", systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 16) {
            Text(controller.signalFormat?.name ?? "—")
                .foregroundStyle(.secondary)
            Text(controller.currentTimecode?.description ?? "--:--:--:--")
                .font(.system(.title3, design: .monospaced).bold())
            Spacer()
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ControlsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 12) {
            Picker("Устройство", selection: $controller.selectedDeviceID) {
                if controller.devices.isEmpty {
                    Text("Нет устройств").tag(String?.none)
                }
                ForEach(controller.devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            .frame(maxWidth: 260)

            Button(controller.isCapturing ? "Остановить захват" : "Запустить захват") {
                controller.isCapturing ? controller.stopCapture() : controller.startCapture()
            }
            .disabled(controller.selectedDeviceID == nil)

            Divider().frame(height: 20)

            TextField("Сцена", text: $controller.scene)
                .frame(width: 80)
            Stepper("Дубль \(controller.nextTakeNumber)",
                    value: $controller.nextTakeNumber, in: 1...999)

            Spacer()

            Button {
                controller.toggleManualRecord()
            } label: {
                Label(controller.isRecording ? "Стоп" : "Запись",
                      systemImage: controller.isRecording ? "stop.fill" : "record.circle")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!controller.isCapturing)
        }
        .padding(12)
    }
}
