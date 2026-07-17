import CDeckLink
import Foundation

// CLI-smoke: проверка моста CDeckLink без UI.
if CDLDeviceManager.isSDKAvailable() {
    let devices = CDLDeviceManager.devices()
    if devices.isEmpty {
        print("SDK доступен, но DeckLink-устройства не найдены")
    } else {
        print("Найдено устройств: \(devices.count)")
        for device in devices {
            print("  \(device.name)  [id: \(device.persistentID)]")
        }
    }
} else {
    print("Собрано без DeckLink SDK (стаб). Положите заголовки в vendor/DeckLinkSDK/include — см. README там же.")
}
