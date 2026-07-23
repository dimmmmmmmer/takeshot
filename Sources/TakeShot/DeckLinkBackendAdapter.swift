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

    private var capture: CDLCapture?
    private var audioFormatDescription: CMAudioFormatDescription?

    override init() {
        super.init()
        // hot-plug: a board plugged/unplugged — the device list refreshes itself
        CDLDeviceManager.startWatchingDevices { [weak self] in
            guard let self else { return }
            self.delegate?.backendDeviceListChanged(self)
        }
    }

    var isAvailable: Bool {
        CDLDeviceManager.isSDKAvailable()
    }

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
            isRGB444: format.isRGB444))
    }

    func capture(_ capture: CDLCapture, didReceiveVideoFrame pixelBuffer: CVPixelBuffer,
                 ptsSeconds: Double, hasTimecode: Bool,
                 tcHours: Int32, tcMinutes: Int32, tcSeconds: Int32, tcFrames: Int32,
                 tcDropFrame: Bool, ancillaryPackets: [CDLAncillaryPacket]) {
        var timecode: Timecode?
        if hasTimecode {
            // the bridge doesn't know the timecode fps — components come with fps 0,
            // the pipeline fills it from the current format
            timecode = Timecode(hours: Int(tcHours), minutes: Int(tcMinutes),
                                seconds: Int(tcSeconds), frames: Int(tcFrames),
                                fps: 0, isDropFrame: tcDropFrame)
        }
        let packets = ancillaryPackets.map {
            AncillaryPacket(did: $0.did, sdid: $0.sdid,
                            lineNumber: $0.lineNumber, data: [UInt8]($0.data))
        }
        delegate?.backend(self, didReceiveFrame: pixelBuffer,
                          pts: CMTime(seconds: ptsSeconds, preferredTimescale: 240_000),
                          timecode: timecode, vancTrigger: nil,
                          ancillaryPackets: packets)
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

/// Merges several backends (DeckLink + demo source, later AJA) into one device
/// list. Device IDs get a backend prefix.
final class AggregateBackend: CaptureBackend {
    weak var delegate: CaptureBackendDelegate? {
        didSet { children.forEach { $0.backend.delegate = self } }
    }

    private let children: [(prefix: String, backend: CaptureBackend)]
    private var activeBackend: CaptureBackend?

    init(children: [(prefix: String, backend: CaptureBackend)]) {
        self.children = children
    }

    var isAvailable: Bool { children.contains { $0.backend.isAvailable } }

    func devices() -> [CaptureDeviceInfo] {
        children.flatMap { child in
            child.backend.devices().map {
                CaptureDeviceInfo(id: "\(child.prefix):\($0.id)", name: $0.name)
            }
        }
    }

    func startCapture(deviceID: String) throws {
        stopCapture()
        guard let separator = deviceID.firstIndex(of: ":"),
              let child = children.first(where: { $0.prefix == deviceID[..<separator] })
        else { return }
        let childDeviceID = String(deviceID[deviceID.index(after: separator)...])
        try child.backend.startCapture(deviceID: childDeviceID)
        activeBackend = child.backend
    }

    func stopCapture() {
        activeBackend?.stopCapture()
        activeBackend = nil
    }

    /// Access to a specific child backend (for special features like demo REC).
    func child<T>(of type: T.Type) -> T? {
        children.first { $0.backend is T }?.backend as? T
    }
}

extension AggregateBackend: CaptureBackendDelegate {
    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        delegate?.backend(self, didDetectFormat: format)
    }

    func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                 pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?,
                 ancillaryPackets: [AncillaryPacket]) {
        delegate?.backend(self, didReceiveFrame: pixelBuffer, pts: pts,
                          timecode: timecode, vancTrigger: vancTrigger,
                          ancillaryPackets: ancillaryPackets)
    }

    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        delegate?.backend(self, didReceiveAudio: sampleBuffer)
    }

    func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        delegate?.backend(self, signalPresent: signalPresent)
    }

    func backendDeviceListChanged(_ backend: CaptureBackend) {
        delegate?.backendDeviceListChanged(self)
    }
}
