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
    /// YCbCr 4:2:2 sources captured as 10-bit v210 (vs 8-bit 2vuy). ON by
    /// default, unlike the 12-bit RGB flag above, and the difference is
    /// deliberate: 12-bit RGB is an exotic format that costs twice the record
    /// bandwidth and that many boards and modes refuse, while v210 is the
    /// BASELINE professional format — it is what an SDI wire carries, every
    /// current Blackmagic board delivers it, and asking for 8-bit means the
    /// driver drops two bits the signal already has. A board that still says no
    /// falls back to 2vuy and the depth that came back is on
    /// `CaptureFormat.bitDepth`.
    var preferTenBitYUV = true

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
        capture.preferTenBitYUV = preferTenBitYUV
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
            timecode: timecode, ancillaryPackets: packets,
            colorimetry: Self.colorimetry(frame.colorimetry)))
    }

    /// The board's HDR report, as the pipeline's own value.
    ///
    /// Two decisions worth stating rather than reading out of the mapping:
    ///
    /// - EOTF 1 ("HDR, traditional gamma" in CTA-861.3) is treated as SDR. It
    ///   names no transfer function anyone can invert — it is a hint that the
    ///   content is bright, not a curve — so tone mapping on it would be
    ///   guessing, and guessing is the one thing this path must not do.
    /// - a PQ or HLG signal whose colorspace the board did not report is taken
    ///   as Rec.2020, because BT.2100 defines PQ and HLG only on Rec.2020
    ///   primaries. Assuming Rec.709 there would silently desaturate every
    ///   HDR source whose camera happens not to fill that field.
    static func colorimetry(
        _ reported: CDLFrameColorimetry?) -> WireColorimetry {
        guard let reported, reported.hasHDRMetadata else { return .sdr }
        let transfer: SignalTransfer
        switch reported.eotf {
        case 2: transfer = .pq
        case 3: transfer = .hlg
        default: transfer = .sdr
        }
        guard transfer.isHDR else { return .sdr }
        let primaries: SignalPrimaries =
            reported.colorspace == 1 || reported.colorspace == 2
                ? .rec709 : .rec2020
        return WireColorimetry(transfer: transfer, primaries: primaries,
                               displayMetadata: displayMetadata(reported))
    }

    /// The static metadata, or nil when the board filled none of it in.
    private static func displayMetadata(
        _ reported: CDLFrameColorimetry) -> HDRStaticMetadata? {
        let hasPrimaries = reported.redX > 0 && reported.greenX > 0
            && reported.blueX > 0 && reported.whiteX > 0
        let value = HDRStaticMetadata(
            maxContentLightLevel: reported.maxContentLightLevel,
            maxFrameAverageLightLevel: reported.maxFrameAverageLightLevel,
            maxDisplayLuminance: reported.maxDisplayLuminance,
            minDisplayLuminance: reported.minDisplayLuminance,
            displayPrimaries: hasPrimaries
                ? HDRStaticMetadata.Chromaticities(
                    redX: reported.redX, redY: reported.redY,
                    greenX: reported.greenX, greenY: reported.greenY,
                    blueX: reported.blueX, blueY: reported.blueY,
                    whiteX: reported.whiteX, whiteY: reported.whiteY)
                : nil)
        return value.isEmpty ? nil : value
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
