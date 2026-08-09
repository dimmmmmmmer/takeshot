import Foundation
import Testing
@testable import TakeShotKit

/// The output picker in Settings is a `ForEach` over these, and the chosen `uid`
/// is what gets written into `AudioSettings.playbackAudioDeviceUID` and handed
/// to the renderer on the next launch. So an entry with an empty uid silently
/// becomes "system default" the moment it is saved, and two entries sharing one
/// breaks the list.
///
/// The assertions hold whether or not the machine running them has any audio
/// hardware — an empty list is a valid answer, a malformed entry is not.
struct ModelAudioDeviceTests {
    @Test func everyListedDeviceIsUsableAsAPickerEntry() {
        for device in AudioOutputDevices.list() {
            #expect(!device.uid.isEmpty, "a device with no UID cannot be saved")
            #expect(!device.name.isEmpty, "a nameless device cannot be picked")
            #expect(device.id == device.uid)
        }
    }

    @Test func deviceIdentifiersAreUnique() {
        let uids = AudioOutputDevices.list().map(\.uid)
        #expect(Set(uids).count == uids.count, "duplicate output UIDs: \(uids)")
    }

    /// The list is polled every time the picker opens; it must be stable rather
    /// than returning a different set each call.
    @Test func listingIsRepeatable() {
        #expect(AudioOutputDevices.list() == AudioOutputDevices.list())
    }
}
