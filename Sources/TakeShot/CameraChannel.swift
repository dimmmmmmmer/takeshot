import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

/// Дополнительная камера в мультикам-режиме: собственный бэкенд-источник +
/// конвейер + превью-слой. Первая (основная) камера живёт прямо в
/// CaptureController; эти — независимые каналы поверх, синхронно пишутся по REC.
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

    /// Колбэк наверх: канал записал дубль (для добавления в общий список).
    var onTakeFinished: ((Take) -> Void)?

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
        pipeline.onRecStateChanged = { [weak self] r in self?.isRecording = r }
        pipeline.onTakeFinished = { [weak self] take in
            guard let self else { return }
            self.takeNumber += 1
            self.onTakeFinished?(take)
        }
    }

    func start() { try? backend.startCapture(deviceID: deviceID) }
    func stop() {
        backend.stopCapture()
        pipeline.captureStopped()
        Task { await pipeline.finishPendingWrites() }
    }

    func update(settings: CaptureSettings, roll: String, takeNumber: Int) {
        var camSettings = settings
        camSettings.cameraLabel = camLabel
        self.takeNumber = takeNumber
        pipeline.update(config: .init(settings: camSettings, roll: roll, takeNumber: takeNumber))
    }

    func setRecording(_ recording: Bool) {
        if recording != isRecording { pipeline.toggleManualRecord() }
    }
}

extension CameraChannel: CaptureBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        pipeline.handleFormat(format)
    }
    nonisolated func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                             pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?,
                             ancillaryPackets: [AncillaryPacket]) {
        pipeline.handleFrame(pixelBuffer: pixelBuffer, pts: pts,
                             timecode: timecode, vancTrigger: vancTrigger,
                             ancillaryPackets: ancillaryPackets)
    }
    nonisolated func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        pipeline.handleAudio(sampleBuffer)
    }
    nonisolated func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        pipeline.handleSignal(present: signalPresent)
    }
    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {}
}
