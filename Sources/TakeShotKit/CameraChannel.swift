import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

/// An extra camera in multicam mode: its own backend source + pipeline +
/// preview layer. The first (main) camera lives directly in CaptureController;
/// these are independent channels on top, recorded in sync by REC.
@MainActor
final class CameraChannel: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let camLabel: String

    let pipeline: CapturePipeline
    private let backend: CaptureBackend
    private let deviceID: String

    @Published var isRecording = false
    @Published var signalFormat: CaptureFormat?
    @Published var currentTimecode: Timecode?
    @Published var signalPresent = true
    @Published var audioLevels: [Float] = []

    /// Callback upward: the channel recorded a take (to add to the shared list).
    var onTakeFinished: ((Take) -> Void)?
    /// Callback upward: a recording failure on this channel. Without it every
    /// integrity message of the extra cameras — writer death, dropped frames,
    /// a take that never finalized — was discarded, and since a take joins the
    /// list only on success, a failed B-cam take left no trace at all.
    var onError: ((String) -> Void)?

    init(camLabel: String, backend: CaptureBackend, deviceID: String,
         settings: CaptureSettings, roll: String) {
        self.camLabel = camLabel
        self.backend = backend
        self.deviceID = deviceID
        var camSettings = settings
        camSettings.cameraLabel = camLabel
        self.pipeline = CapturePipeline(config: .init(
            settings: camSettings, roll: roll, takeNumber: 1))
        bind()
        backend.delegate = self
    }

    private var takeNumber = 1

    private func bind() {
        pipeline.onFormatChanged = { [weak self] f in self?.signalFormat = f }
        pipeline.onTimecode = { [weak self] tc in self?.currentTimecode = tc }
        pipeline.onSignal = { [weak self] p in self?.signalPresent = p }
        pipeline.onAudioLevels = { [weak self] l in self?.audioLevels = l }
        pipeline.onRecStateChanged = { [weak self] r in
            self?.isRecording = r
            // the pipeline can close a take on its own (writer failure, format
            // change) — drop the request with it, or the next REC would be
            // read as "already recording" and swallowed
            if !r { self?.recordingRequested = false }
        }
        pipeline.onTakeFinished = { [weak self] take in
            guard let self else { return }
            self.takeNumber += 1
            self.onTakeFinished?(take)
        }
        pipeline.onError = { [weak self] message in
            guard let self else { return }
            self.onError?("\(self.camLabel): \(message)")
        }
    }

    /// Start capture; the error surfaces to the operator (a board held by
    /// another app used to fail completely silently).
    func start() throws {
        try backend.startCapture(deviceID: deviceID)
        pipeline.setExpectedAudioChannels(backend.embeddedAudioChannels)
    }

    func stop() {
        stopStreams()
        Task { await pipeline.finishPendingWrites() }
    }

    /// Synchronous part of stop — flushOnTerminate awaits the writes itself.
    func stopStreams() {
        backend.stopCapture()
        pipeline.captureStopped()
        recordingRequested = false
    }

    func update(settings: CaptureSettings, slate: SlateMetadata = .empty,
                roll: String, takeNumber: Int) {
        var camSettings = settings
        camSettings.cameraLabel = camLabel
        self.takeNumber = takeNumber
        pipeline.update(config: .init(settings: camSettings, slate: slate,
                                      roll: roll, takeNumber: takeNumber))
    }

    /// What REC has asked of this channel. Deliberately NOT `isRecording`: that
    /// one only flips once the pipeline reports back, which happens after the
    /// pre-roll drain (up to 1.5 s). A take short enough to stop inside that
    /// window used to leave the request unmatched — the channel kept writing,
    /// the next start was swallowed as "already recording", and B-cam ran one
    /// continuous clip out of phase with A-cam for the rest of the day.
    private var recordingRequested = false

    func setRecording(_ recording: Bool) {
        guard recording != recordingRequested else { return }
        recordingRequested = recording
        pipeline.toggleManualRecord()
    }
}

/// Straight through to this channel's own pipeline — see
/// `PipelineBackendDelegate` for the five bodies and for why they are shared
/// with the main camera.
extension CameraChannel: PipelineBackendDelegate {}
