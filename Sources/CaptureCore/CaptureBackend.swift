import CoreMedia
import CoreVideo
import Foundation

/// Описание капчур-устройства (плата/вход).
public struct CaptureDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: String          // персистентный ID устройства
    public var name: String        // "UltraStudio Recorder 3G"

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// События входного сигнала. Колбэки приходят с фонового потока захвата.
public protocol CaptureBackendDelegate: AnyObject {
    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat)
    func backend(_ backend: CaptureBackend, didReceiveFrame pixelBuffer: CVPixelBuffer,
                 pts: CMTime, timecode: Timecode?, vancTrigger: VancTrigger?)
    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer)
    func backend(_ backend: CaptureBackend, signalPresent: Bool)
    func backendDeviceListChanged(_ backend: CaptureBackend)
}

/// Абстракция капчур-слоя. Реализации: DeckLinkBackend (MVP), позже — AJA NTV2.
public protocol CaptureBackend: AnyObject {
    var delegate: CaptureBackendDelegate? { get set }
    var isAvailable: Bool { get }          // false, если SDK/драйвер не найден
    func devices() -> [CaptureDeviceInfo]
    func startCapture(deviceID: String) throws
    func stopCapture()
}
