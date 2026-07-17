import AVFoundation
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

/// Живое превью входного сигнала (AVSampleBufferDisplayLayer из конвейера).
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            DisplayLayerView(layer: controller.pipeline.displayLayer)
            if !controller.isCapturing {
                if controller.devices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 40))
                        Text(controller.backendAvailable
                             ? L("no_devices_found")
                             : L("sdk_not_connected"))
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(L("capture_not_running"))
                        .foregroundStyle(.secondary)
                }
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
        layer.backgroundColor = .black
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
            Picker(L("device"), selection: $controller.selectedDeviceID) {
                if controller.devices.isEmpty {
                    Text(L("no_devices")).tag(String?.none)
                }
                ForEach(controller.devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            .frame(maxWidth: 280)
            .disabled(controller.isCapturing)

            Button(controller.isCapturing ? L("stop_capture") : L("start_capture")) {
                controller.isCapturing ? controller.stopCapture() : controller.startCapture()
            }
            .disabled(controller.selectedDeviceID == nil)

            Divider().frame(height: 20)

            TextField(L("scene"), text: $controller.scene)
                .frame(width: 80)
            Stepper(L("take_n", controller.nextTakeNumber),
                    value: $controller.nextTakeNumber, in: 1...999)

            Spacer()

            if controller.isMockSelected && controller.isCapturing {
                Button {
                    controller.toggleMockCameraRecord()
                } label: {
                    Label(controller.mockCameraRecording ? L("mock_rec_stop") : L("mock_rec"),
                          systemImage: "video.fill")
                }
                .tint(controller.mockCameraRecording ? .red : nil)
                .help(L("mock_rec_help"))
            }

            Button {
                controller.toggleManualRecord()
            } label: {
                Label(controller.isRecording ? L("stop") : L("record"),
                      systemImage: controller.isRecording ? "stop.fill" : "record.circle")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!controller.isCapturing)
        }
        .padding(12)
    }
}
