import CaptureCore
import CDeckLink
import CoreMedia
import CoreVideo
import Foundation

/// Swift wrapper over the Obj-C++ CDeckLink bridge, implementing CaptureBackend.
/// CDLCapture callbacks arrive on the DeckLink thread and pass through to the delegate as-is.
final class DeckLinkBackendAdapter: NSObject, CaptureBackend {
    weak var delegate: CaptureBackendDelegate?

    /// Forced input mode (name + RGB flag); nil — autodetect. Set before start.
    var forcedMode: (name: String, rgb: Bool)?
    /// RGB 4:4:4 sources captured as 10-bit r210 (vs 8-bit BGRA).
    var preferTenBitRGB = true
    /// RGB 4:4:4 sources captured as 12-bit R12B. Off by default: it is only
    /// worth the bandwidth on a board and a source that both deliver it, and a
    /// request the hardware refuses falls back (see `rgbPixelFormatForMode` in
    /// the bridge) — the depth that came back is on `CaptureFormat.bitDepth`.
    var preferTwelveBitRGB = false

    private var capture: CDLCapture?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// The discovery callback is a bridge-level SINGLETON — a second adapter
    /// (multicam channels) registering would silently replace the primary's
    /// hot-plug handling with a no-op.
    init(watchesDevices: Bool = true) {
        super.init()
        guard watchesDevices else { return }
        // hot-plug: a board plugged/unplugged — the device list refreshes itself
        CDLDeviceManager.startWatchingDevices { [weak self] in
            guard let self else { return }
            self.delegate?.backendDeviceListChanged(self)
        }
    }

    var isAvailable: Bool {
        CDLDeviceManager.isSDKAvailable()
    }

    /// The bridge enables the audio input with a fixed channel count, so the
    /// writer can be given an audio track before the first packet arrives.
    var embeddedAudioChannels: Int { CDLCapture.embeddedAudioChannels() }

    func devices() -> [CaptureDeviceInfo] {
        CDLDeviceManager.devices().map {
            CaptureDeviceInfo(id: $0.persistentID, name: $0.name)
        }
    }

    func startCapture(deviceID: String) throws {
        stopCapture()
        let capture = CDLCapture()
        capture.delegate = self
        if let forcedMode {
            capture.forcedModeName = forcedMode.name
            capture.forcedRGB = forcedMode.rgb
        }
        capture.preferTenBitRGB = preferTenBitRGB
        capture.preferTwelveBitRGB = preferTwelveBitRGB
        try capture.start(withDeviceID: deviceID)
        self.capture = capture
    }

    /// Input mode names of a device (for the Settings picker).
    static func inputModeNames(deviceID: String) -> [String] {
        CDLDeviceManager.displayModeNames(forDevice: deviceID)
    }

    func stopCapture() {
        capture?.stop()
        capture = nil
    }
}

extension DeckLinkBackendAdapter: CDLCaptureDelegate {
    func capture(_ capture: CDLCapture, didDetect format: CDLVideoFormat) {
        let fps = format.frameRate
        // flag 29.97/59.94 as potential drop-frame; the actual DF flag arrives
        // with each frame's timecode
        let fractional = abs(fps.rounded() - fps) > 0.01
        delegate?.backend(self, didDetectFormat: CaptureFormat(
            width: format.width, height: format.height,
            frameRate: fps, timecodeFPS: Int(format.timecodeFPS),
            isDropFrame: fractional, name: format.modeName,
            isRGB444: format.isRGB444, bitDepth: Int(format.bitDepth)))
    }

    // This is the boundary where the bridge's plain values become domain types.
    func capture(_ capture: CDLCapture, didReceiveVideoFrame frame: CDLCapturedFrame) {
        var timecode: Timecode?
        if frame.hasTimecode {
            // the bridge doesn't know the timecode fps — components come with fps 0,
            // the pipeline fills it from the current format
            timecode = Timecode(hours: Int(frame.tcHours), minutes: Int(frame.tcMinutes),
                                seconds: Int(frame.tcSeconds), frames: Int(frame.tcFrames),
                                fps: 0, isDropFrame: frame.tcDropFrame)
        }
        let packets = frame.ancillaryPackets.map {
            AncillaryPacket(did: $0.did, sdid: $0.sdid,
                            lineNumber: $0.lineNumber, data: [UInt8]($0.data))
        }
        delegate?.backend(self, didReceive: CapturedFrame(
            pixelBuffer: frame.pixelBuffer,
            pts: CMTime(seconds: frame.ptsSeconds, preferredTimescale: 240_000),
            timecode: timecode, ancillaryPackets: packets))
    }

    func capture(_ capture: CDLCapture, didReceiveAudioBytes bytes: UnsafeRawPointer,
                 sampleFrames: UInt32, channelCount: UInt32, ptsSeconds: Double) {
        guard let sampleBuffer = makeAudioSampleBuffer(
            bytes: bytes, sampleFrames: Int(sampleFrames),
            channelCount: Int(channelCount), ptsSeconds: ptsSeconds)
        else { return }
        delegate?.backend(self, didReceiveAudio: sampleBuffer)
    }

    func capture(_ capture: CDLCapture, signalPresent present: Bool) {
        delegate?.backend(self, signalPresent: present)
    }

    // MARK: - PCM → CMSampleBuffer

    private func makeAudioSampleBuffer(bytes: UnsafeRawPointer, sampleFrames: Int,
                                       channelCount: Int, ptsSeconds: Double) -> CMSampleBuffer? {
        PCMAudio.makeSampleBuffer(bytes: bytes, sampleFrames: sampleFrames,
                                  channelCount: channelCount, ptsSeconds: ptsSeconds,
                                  formatCache: &audioFormatDescription)
    }
}
