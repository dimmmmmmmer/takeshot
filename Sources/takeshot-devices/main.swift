import CDeckLink
import Foundation

// CLI smoke test: check the CDeckLink bridge without a UI.
if CDLDeviceManager.isSDKAvailable() {
    let devices = CDLDeviceManager.devices()
    if devices.isEmpty {
        print("SDK available, but no DeckLink devices found")
    } else {
        print("Devices found: \(devices.count)")
        for device in devices {
            print("  \(device.name)  [id: \(device.persistentID)]")
        }
    }
} else {
    print("Built without the DeckLink SDK (stub). "
          + "Put the headers in vendor/DeckLinkSDK/include — see the README there.")
}
