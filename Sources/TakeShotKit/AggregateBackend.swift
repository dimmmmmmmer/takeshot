import CaptureCore
import CoreMedia
import Foundation

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

    /// Whatever the source that is actually running reports.
    var embeddedAudioChannels: Int { activeBackend?.embeddedAudioChannels ?? 0 }

    func devices() -> [CaptureDeviceInfo] {
        children.flatMap { child in
            child.backend.devices().map {
                CaptureDeviceInfo(id: "\(child.prefix):\($0.id)", name: $0.name)
            }
        }
    }

    enum AggregateError: LocalizedError {
        case unknownDevice(String)
        var errorDescription: String? {
            if case .unknownDevice(let id) = self {
                return "Unknown capture device \"\(id)\""
            }
            return nil
        }
    }

    func startCapture(deviceID: String) throws {
        stopCapture()
        guard let separator = deviceID.firstIndex(of: ":"),
              let child = children.first(where: { $0.prefix == deviceID[..<separator] })
        else {
            // returning silently made the UI show "capturing" over nothing
            throw AggregateError.unknownDevice(deviceID)
        }
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

    func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame) {
        delegate?.backend(self, didReceive: frame)
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
