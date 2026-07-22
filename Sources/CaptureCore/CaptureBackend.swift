import CoreMedia
import CoreVideo
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

/// Input-signal events. Callbacks arrive on the background capture thread.
public protocol CaptureBackendDelegate: AnyObject {
    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat)
    func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                 pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?,
                 ancillaryPackets: [AncillaryPacket])
    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer)
    func backend(_ backend: CaptureBackend, signalPresent: Bool)
    func backendDeviceListChanged(_ backend: CaptureBackend)
}

/// Capture-layer abstraction. Implementations: DeckLinkBackend (MVP), later AJA NTV2.
public protocol CaptureBackend: AnyObject {
    var delegate: CaptureBackendDelegate? { get set }
    var isAvailable: Bool { get }          // false if the SDK/driver isn't found
    func devices() -> [CaptureDeviceInfo]
    func startCapture(deviceID: String) throws
    func stopCapture()
}
