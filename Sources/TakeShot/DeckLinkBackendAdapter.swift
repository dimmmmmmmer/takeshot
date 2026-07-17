import CaptureCore
import CDeckLink
import CoreMedia
import Foundation

/// Swift-обёртка над Obj-C++ мостом CDeckLink, реализующая CaptureBackend.
/// Захват кадров подключается на этапе 2 (после установки DeckLink SDK);
/// сейчас — перечисление устройств и признак доступности SDK.
final class DeckLinkBackendAdapter: CaptureBackend {
    weak var delegate: CaptureBackendDelegate?

    var isAvailable: Bool {
        CDLDeviceManager.isSDKAvailable()
    }

    func devices() -> [CaptureDeviceInfo] {
        CDLDeviceManager.devices().map {
            CaptureDeviceInfo(id: $0.persistentID, name: $0.name)
        }
    }

    func startCapture(deviceID: String) throws {
        throw CaptureError.notImplemented
    }

    func stopCapture() {}

    enum CaptureError: LocalizedError {
        case notImplemented

        var errorDescription: String? {
            "Захват будет доступен после подключения DeckLink SDK (этап 2)"
        }
    }
}
