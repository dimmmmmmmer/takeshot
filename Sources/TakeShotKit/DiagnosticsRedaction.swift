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
/// 4. **Bulk opaque values are summarised.** Some settings are data rather than
///    a choice — the taught REC indicator's two references are 256 characters of
///    base64 each. The bundle exists to be READ, and a screen of base64 in it
///    buries the lines next to it. Anything past `maxValueLength` is replaced by
///    its length, generically, so the same happens to whatever is stored that
///    way next. What such a setting is actually DOING is reported in words
///    elsewhere (see `CaptureController.diagnosticsVisualRec`).
///
/// Not covered here because they are simply never collected: the machine's
/// name, the logged-in user, IP addresses, and any footage.
enum DiagnosticsRedaction {
    /// What makes a settings key a secret. Matched against the key's own
    /// camel-case components, so `remotePIN` goes without being named here.
    static let secretKeyMarkers = ["pin", "password", "passcode", "secret",
                                   "token", "credential"]

    /// A key's camel-case components, lowercased.
    ///
    /// `remotePIN` is `["remote", "pin"]` and `keepInMenuBar` is
    /// `["keep", "in", "menu", "bar"]`. A run of capitals stays whole, so an
    /// acronym is one component and not a string of letters: `PINCode` comes
    /// out `["pin", "code"]`.
    static func components(of key: String) -> [String] {
        let characters = Array(key)
        var parts: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            var startsWord = false
            if character.isUppercase, let previous {
                // a capital after a lower-case letter opens a word
                // ("remote|PIN"), and so does the last capital of a run when a
                // lower-case letter follows it ("PIN|Code")
                startsWord = !previous.isUppercase
                    || (next?.isLowercase ?? false)
            }
            if startsWord, !current.isEmpty {
                parts.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current.lowercased()) }
        return parts
    }

    /// Is this key a credential?
    ///
    /// A marker has to BEGIN one of the key's components. That is a tightening
    /// of a plain `contains`, and it was not theoretical: `keepInMenuBar`
    /// lowercases to "kee**pin**menubar", so the setting was dropped from every
    /// diagnostics bundle ever produced — the "pin" there spans the join
    /// between `keep` and `In` and belongs to neither.
    ///
    /// Still deliberately loose in the direction that matters. The marker is a
    /// PREFIX of a component rather than the whole of it, so `secrets`,
    /// `pinCode` and `tokenA` are all caught: a false positive costs one line
    /// of a diagnostic, a false negative costs a credential. What it will not
    /// catch is a key written as one run-together lower-case word
    /// (`mypinvalue`) — Swift property names are camel case, and the whole key
    /// set is pinned in `SettingsFormatFixture`, so a new one is visible in
    /// review rather than only here.
    static func isSecretKey(_ key: String) -> Bool {
        let parts = components(of: key)
        return secretKeyMarkers.contains { marker in
            parts.contains { $0.hasPrefix(marker) }
        }
    }

    /// How long a settings value may be before it is summarised instead of
    /// printed (rule 4). Generous enough for every path, template and hex colour
    /// in the blob — the longest real one is a destination path — and well under
    /// the 256 characters an encoded reference takes.
    static let maxValueLength = 120

    /// A value as the bundle prints it: itself, or its size when it is bulk data
    /// nobody can read. By LENGTH rather than by key name, so the rule applies to
    /// whatever is stored that way next without anyone having to remember it.
    static func summarised(_ value: String) -> String {
        guard value.count > maxValueLength else { return value }
        return "<\(value.count) characters of data>"
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
            return summarised(abbreviate(string))
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
