@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// Description of a capture device (board/input).
public struct CaptureDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: String          // persistent device ID
    public var name: String        // "UltraStudio Recorder 3G"

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything one captured video frame carries. A value rather than a growing
/// parameter list: the list gained VANC triggers and then ancillary packets,
/// and every implementer had to be edited in lockstep each time.
public struct CapturedFrame {
    public var pixelBuffer: CVPixelBuffer
    /// Presentation time on the capture timeline (the backend's own base).
    public var pts: CMTime
    public var timecode: Timecode?
    public var vancTrigger: VancTrigger?
    public var ancillaryPackets: [AncillaryPacket]
    /// What the source says its code values MEAN — transfer function,
    /// primaries and any static HDR metadata.
    ///
    /// On the FRAME rather than on `CaptureFormat`, and that is a property of
    /// the hardware rather than a design preference: the DeckLink format
    /// -detection callback's flags say nothing about HDR at all (they carry
    /// sampling, bit depth and 3D and stop there). HDR arrives as per-frame
    /// metadata — the CTA-861.3 InfoFrame over HDMI, the ST 352 payload ID over
    /// SDI — and the board surfaces it through the frame's metadata extensions.
    /// So the app learns it from a frame or not at all, and a mid-shot change
    /// is visible instead of being pinned to whenever the mode last changed.
    ///
    /// `.sdr` for every backend that does not know, which is every backend
    /// except a DeckLink built against the SDK.
    public var colorimetry: WireColorimetry

    public init(pixelBuffer: CVPixelBuffer, pts: CMTime,
                timecode: Timecode? = nil, vancTrigger: VancTrigger? = nil,
                ancillaryPackets: [AncillaryPacket] = [],
                colorimetry: WireColorimetry = .sdr) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.timecode = timecode
        self.vancTrigger = vancTrigger
        self.ancillaryPackets = ancillaryPackets
        self.colorimetry = colorimetry
    }
}

/// Input-signal events. Callbacks arrive on the background capture thread.
public protocol CaptureBackendDelegate: AnyObject {
    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat)
    func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame)
    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer)
    func backend(_ backend: CaptureBackend, signalPresent: Bool)
    func backendDeviceListChanged(_ backend: CaptureBackend)
}

/// Capture-layer abstraction. Implementations: DeckLinkBackend (MVP), later AJA NTV2.
public protocol CaptureBackend: AnyObject {
    var delegate: CaptureBackendDelegate? { get set }
    var isAvailable: Bool { get }          // false if the SDK/driver isn't found
    /// Channels the backend's audio input is configured for, known before the
    /// first packet arrives. The writer's audio track is created when the take
    /// starts, and a take can start on capture frame 1 (a VANC trigger fires
    /// with no debounce) — deriving the count from the first audio packet meant
    /// such a take was written with no audio track at all. 0 — unknown.
    var embeddedAudioChannels: Int { get }
    func devices() -> [CaptureDeviceInfo]
    func startCapture(deviceID: String) throws
    func stopCapture()
}

public extension CaptureBackend {
    /// Backends that cannot state it up front keep the old behaviour: the count
    /// is learned from the first audio packet.
    var embeddedAudioChannels: Int { 0 }
}
