import CaptureCore
import Foundation

/// What never leaves the machine, and what is toned down on the way out.
///
/// The bundle exists to be sent to someone, so privacy is part of producing it
/// rather than a warning printed next to it. Three rules, and they are all
/// here rather than at the call sites:
///
/// 1. **Secrets are dropped, not masked.** The remote PIN is the only one today.
///    It is removed by NAME, generically, so a credential added to
///    `CaptureSettings` later is dropped by this code without anyone having to
///    remember it — a four-digit PIN cannot safely be removed by searching for
///    its value, because "1080" is also a raster.
/// 2. **The account name goes.** Every path is written with the home directory
///    abbreviated to `~`, which is what carries the operator's own name.
/// 3. **The production stays, and is declared.** The project name, the scene,
///    the roll and the take file names are the evidence — a bundle that
///    redacted them would not diagnose anything. So they are kept and the top
///    of the report says plainly that they are there, which is the decision the
///    owner has to be given rather than made for.
///
/// Not covered here because they are simply never collected: the machine's
/// name, the logged-in user, IP addresses, and any footage.
enum DiagnosticsRedaction {
    /// Substrings that make a settings key a secret. Matched case-insensitively
    /// against the key name, so `remotePIN` goes without being named.
    static let secretKeyMarkers = ["pin", "password", "passcode", "secret",
                                   "token", "credential"]

    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return secretKeyMarkers.contains { lowered.contains($0) }
    }

    /// Every occurrence of the home directory replaced by `~`. Applied to
    /// paths, and to the log excerpt — the folder watcher logs the record
    /// folder's full path, which starts with the operator's account name.
    static func abbreviate(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    static func abbreviate(_ url: URL) -> String {
        abbreviate(url.path)
    }

    /// `CaptureSettings` as flat, sorted, printable key/value pairs with the
    /// secrets gone and the paths abbreviated.
    ///
    /// Routed through the type's own `Codable` conformance rather than a
    /// hand-written field list: a settings field added next month appears in
    /// the bundle by itself, which is the behaviour a diagnostic wants, and
    /// rule 1 above is what keeps that from being dangerous.
    static func settings(_ settings: CaptureSettings) -> [String: String] {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in fields where !isSecretKey(key) {
            out[key] = describe(value)
        }
        return out
    }

    /// One JSON value as a line of text. `JSONSerialization` hands booleans
    /// back as `NSNumber`, so they need telling apart from 0 and 1 explicitly —
    /// "monitorEnabled = 0" reads as a level, not a switch.
    private static func describe(_ value: Any) -> String {
        switch value {
        case let string as String:
            return abbreviate(string)
        case let array as [Any]:
            return array.map(describe).joined(separator: ", ")
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case is NSNull:
            return "null"
        default:
            return String(describing: value)
        }
    }
}
