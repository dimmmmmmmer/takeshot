import AVFoundation
import CaptureCore
import CoreMedia
import Foundation

/// Captures PCM from one external audio input (the sound cart's mix over a
/// USB interface) and delivers it in the pipeline's expected wire format —
/// 48 kHz interleaved Int16, the same shape the capture boards embed. Packets
/// leave here still on the HOST clock; `CapturePipeline+ExternalAudio` owns
/// the host→stream alignment, because only the frame path sees both clocks.
///
/// It lives in TakeShotKit with the other device adapters (the DeckLink
/// adapter, the demo source, the output-device walk): CaptureCore stays the
/// SDK- and hardware-free core, and this type's whole job is standing between
/// real hardware and that core.
///
/// Threading: the device delivers serially on its own queue and every bit of
/// converter state is confined to that delivery; `onPacket` fires there too.
/// The pipeline's `handleAudio` hops to its own queue immediately, so the
/// device's queue is never blocked on anything downstream.
final class ExternalAudioSource {
    /// The pipeline's wire format rate — what the boards deliver and what
    /// `TakeWriter`'s audio input is configured for.
    static let targetSampleRate = 48_000.0

    /// Interleaved Int16 at `sampleRate` for any channel count. AVAudioFormat's
    /// plain initializers return nil past two channels — a multichannel format
    /// needs an explicit layout, and for interleaved wire audio the channels
    /// are positional, so discrete-in-order is the honest one (the same tag
    /// TakeWriter tags its >2-channel tracks with).
    static func int16Format(sampleRate: Double,
                            channels: AVAudioChannelCount) -> AVAudioFormat? {
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatInt16,
                             sampleRate: sampleRate,
                             interleaved: true, channelLayout: layout)
    }

    let deviceUID: String
    var channelCount: Int { device.channelCount }
    /// A converted packet, host-clock PTS. Set before `start`.
    var onPacket: ((CMSampleBuffer) -> Void)?
    /// The device disappeared mid-capture. Set before `start`.
    var onDeviceGone: (() -> Void)?

    private let device: AudioCaptureDevice
    // Converter state — confined to the device's serial delivery queue.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var packetFormatCache: CMAudioFormatDescription?
    private var basePTS: CMTime?
    private var framesDelivered: Int64 = 0

    init(device: AudioCaptureDevice) {
        self.device = device
        self.deviceUID = device.uid
    }

    func start() throws {
        device.onBuffer = { [weak self] buffer, pts in
            self?.ingest(buffer, at: pts)
        }
        device.onDeviceGone = { [weak self] in self?.onDeviceGone?() }
        try device.start()
    }

    func stop() {
        device.stop()
        device.onBuffer = nil
        device.onDeviceGone = nil
    }

    // MARK: - on the device's delivery queue

    private func ingest(_ buffer: AVAudioPCMBuffer, at pts: CMTime) {
        guard let converted = convert(buffer),
              converted.frameLength > 0 else { return }
        emit(converted, inputPTS: pts)
    }

    /// Output PTS runs contiguously from the first input's host timestamp,
    /// counted in OUTPUT frames: resampling changes the frame count, so the
    /// device's own stamps cannot be reused per packet. If the synthetic
    /// clock drifts from the device's stamps (a dropout inside the device),
    /// it re-anchors and accepts the jump — the pipeline's overlap guard and
    /// the monitor's resync both handle a discontinuity.
    private func emit(_ converted: AVAudioPCMBuffer, inputPTS: CMTime) {
        if let base = basePTS {
            let synthetic = CMTimeAdd(base, CMTime(value: framesDelivered,
                                                   timescale: 48_000))
            if abs(CMTimeSubtract(synthetic, inputPTS).seconds) > 0.06 {
                basePTS = inputPTS
                framesDelivered = 0
            }
        } else {
            basePTS = inputPTS
        }
        guard let base = basePTS else { return }
        let packetPTS = CMTimeAdd(base, CMTime(value: framesDelivered,
                                               timescale: 48_000))
        let frames = Int(converted.frameLength)
        framesDelivered += Int64(frames)
        // interleaved Int16: one buffer, frames × channels samples
        guard let samples = converted.int16ChannelData?[0] else { return }
        let packet = PCMAudio.makeSampleBuffer(
            bytes: samples, sampleFrames: frames,
            channelCount: Int(converted.format.channelCount),
            ptsSeconds: packetPTS.seconds,
            formatCache: &packetFormatCache)
        if let packet { onPacket?(packet) }
    }

    /// The device's native format → 48 kHz interleaved Int16. A buffer that
    /// already is the target format passes through untouched.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if inputFormat.commonFormat == .pcmFormatInt16, inputFormat.isInterleaved,
           inputFormat.sampleRate == Self.targetSampleRate {
            return buffer
        }
        if converter == nil || converterInputFormat != inputFormat {
            guard let outputFormat = Self.int16Format(
                    sampleRate: Self.targetSampleRate,
                    channels: inputFormat.channelCount),
                  let fresh = AVAudioConverter(from: inputFormat, to: outputFormat)
            else { return nil }
            converter = fresh
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }
        let ratio = Self.targetSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: capacity)
        else { return nil }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                // .noDataNow, not .endOfStream: the stream continues with the
                // next capture callback, and ending it would flush the
                // converter's resampling state between packets
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return out
    }
}
