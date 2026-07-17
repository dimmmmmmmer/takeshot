import CaptureCore
import CDeckLink
import CoreMedia
import CoreVideo
import Foundation

/// Swift-обёртка над Obj-C++ мостом CDeckLink, реализующая CaptureBackend.
/// Колбэки CDLCapture приходят с потока DeckLink и пробрасываются делегату как есть.
final class DeckLinkBackendAdapter: NSObject, CaptureBackend {
    weak var delegate: CaptureBackendDelegate?

    private var capture: CDLCapture?
    private var audioFormatDescription: CMAudioFormatDescription?

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
        try capture.start(withDeviceID: deviceID)
        self.capture = capture
    }

    func stopCapture() {
        capture?.stop()
        capture = nil
    }
}

extension DeckLinkBackendAdapter: CDLCaptureDelegate {
    func capture(_ capture: CDLCapture, didDetect format: CDLVideoFormat) {
        let fps = format.frameRate
        // 29.97/59.94 сигнализируем как потенциальный drop-frame; фактический
        // флаг DF придёт с таймкодом каждого кадра
        let fractional = abs(fps.rounded() - fps) > 0.01
        delegate?.backend(self, didDetectFormat: CaptureFormat(
            width: format.width, height: format.height,
            frameRate: fps, timecodeFPS: Int(format.timecodeFPS),
            isDropFrame: fractional, name: format.modeName))
    }

    func capture(_ capture: CDLCapture, didReceiveVideoFrame pixelBuffer: CVPixelBuffer,
                 ptsSeconds: Double, hasTimecode: Bool,
                 tcHours: Int32, tcMinutes: Int32, tcSeconds: Int32, tcFrames: Int32,
                 tcDropFrame: Bool) {
        var timecode: Timecode?
        if hasTimecode {
            // fps таймкода уточняется по величине поля frames в RecDetector не нужен —
            // берём из последнего формата через delegate-цепочку; здесь достаточно
            // передать компоненты с номинальным fps, его проставит конвейер
            timecode = Timecode(hours: Int(tcHours), minutes: Int(tcMinutes),
                                seconds: Int(tcSeconds), frames: Int(tcFrames),
                                fps: 0, isDropFrame: tcDropFrame)
        }
        delegate?.backend(self, didReceiveFrame: pixelBuffer,
                          pts: CMTime(seconds: ptsSeconds, preferredTimescale: 240_000),
                          timecode: timecode, vancTrigger: nil)
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
        if audioFormatDescription == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * channelCount),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * channelCount),
                mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 16,
                mReserved: 0)
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &audioFormatDescription)
        }
        guard let formatDescription = audioFormatDescription else { return nil }

        let dataLength = sampleFrames * 2 * channelCount
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: dataLength, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { return nil }
        guard CMBlockBufferReplaceDataBytes(
            with: bytes, blockBuffer: blockBuffer,
            offsetIntoDestination: 0, dataLength: dataLength) == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: sampleFrames,
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 240_000),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}

/// Объединяет несколько бэкендов (DeckLink + демо-источник, позже AJA)
/// в один список устройств. ID устройств получают префикс бэкенда.
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

    /// Доступ к конкретному дочернему бэкенду (для спец-функций вроде демо-REC).
    func child<T>(of type: T.Type) -> T? {
        children.first { $0.backend is T }?.backend as? T
    }
}

extension AggregateBackend: CaptureBackendDelegate {
    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        delegate?.backend(self, didDetectFormat: format)
    }

    func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                 pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?) {
        delegate?.backend(self, didReceiveFrame: pixelBuffer, pts: pts,
                          timecode: timecode, vancTrigger: vancTrigger)
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
