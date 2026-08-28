import CBraw
import CDataChannel
import CDeckLink
import CNDI
import CR3D
import CSRT
import Foundation

@testable import TakeShotKit

/// What the six SDK bridges can say about themselves, in one place, read off
/// the bridges' own constants rather than typed out.
///
/// A list rather than a suite because two suites need it —
/// `BridgeLocalizationTests` asks whether both `.strings` tables have words for
/// every code, `BridgeErrorLocalizationTests` asks whether what a real bridge
/// hands back is in it — and a code added to one copy and not the other is
/// exactly the drift they exist to catch.
enum BridgeVocabulary {
    /// Every code the six bridges can state, read from the bridges' own
    /// constants rather than typed out here.
    ///
    /// That is what makes this list unable to go stale: renaming a code in the
    /// Obj-C without adding the key fails `everyCodeHasWordsInBothLanguages`
    /// by name, where a copied list would keep asserting about a string
    /// nothing produces any more.
    static let codes: [String] = [
        CSRTUnavailableNotBuilt, CSRTUnavailableRuntimeMissing,
        CSRTUnavailableRuntimeIncomplete, CSRTUnavailableRuntimeRefused,
        CNDUnavailableNotBuilt, CNDUnavailableRuntimeMissing,
        CNDUnavailableRuntimeIncomplete, CNDUnavailableRuntimeRefused,
        CDCUnavailableNotBuilt, CDCUnavailableRuntimeMissing,
        CDCUnavailableRuntimeIncomplete, CDCUnavailableRuntimeNoMedia,
        CDLUnavailableNotBuilt, CDLUnavailableDeviceMissing,
        CDLUnavailableDeviceBusy, CDLUnavailableWrongDevice,
        CDLUnavailableModeUnsupported, CDLUnavailableRuntimeRefused,
        CBRUnavailableNotBuilt, CBRUnavailableRuntimeMissing,
        CBRUnavailableRuntimeRefused, CBRUnavailableClipUnreadable,
        CR3DUnavailableNotBuilt, CR3DUnavailableRuntimeMissing,
        CR3DUnavailableRuntimeIncomplete, CR3DUnavailableRuntimeRefused,
    ]

    /// The six whose sentence takes an argument, and so the only six that may
    /// carry a placeholder: three name the paths a dlopen looked at, and three
    /// name a device, a raster and a file.
    static let codesCarryingAValue: [String] = [
        CSRTUnavailableRuntimeMissing, CNDUnavailableRuntimeMissing,
        CDCUnavailableRuntimeMissing, CDLUnavailableDeviceMissing,
        CDLUnavailableModeUnsupported, CBRUnavailableClipUnreadable,
    ]

    /// The three `not_built` lines that arrived with the media bridges. Every
    /// one of them is what a downloaded DMG shows, because a published release
    /// is built with no vendor drops at all — and DeckLink's is the one that
    /// decides whether an operator can capture at all.
    static let mediaStubCodes: [String] = [
        CDLUnavailableNotBuilt, CBRUnavailableNotBuilt, CR3DUnavailableNotBuilt,
    ]

    /// An `NSError` shaped exactly the way `CDeckLink` and `CBraw` shape theirs,
    /// for the cases no machine can be relied on to produce.
    static func error(code: String?, english: String,
                      detail: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: english]
        if let code { info[BridgeUnavailable.codeKey] = code }
        if let detail { info[BridgeUnavailable.detailKey] = detail }
        return NSError(domain: "com.takeshot.test", code: 1, userInfo: info)
    }
}
