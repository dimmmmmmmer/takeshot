import Foundation

/// What the phone in the director's hand is told, and what it may ask for.
///
/// Both types are plain values with no reference to the controller: the status
/// is built on the MainActor and handed to the server's own queue, the command
/// is parsed on the server's queue and handed to the MainActor. Sendable
/// structs are what keeps that hand-off from being a shared-state problem.
struct RemoteStatus: Equatable, Sendable {
    /// Timecode as the footer shows it; empty while there is no signal.
    var timecode: String = ""
    var recording = false
    var capturing = false
    /// Signal format name ("1080p25"); empty when nothing is detected.
    var format: String = ""
    /// The take being written, or the last one that landed.
    var takeName: String = ""
    /// "none" / "good" / "bad" — the last take's rating.
    var rating: String = "none"
    /// Free space on the record volume, GB. -1 when it cannot be read (the
    /// volume was pulled), which the page shows as a dash rather than as 0 GB.
    var diskFreeGB: Double = -1
    /// Markers on the take in progress, or on the last one.
    var markerCount: Int = 0

    /// The wire form. Hand-built rather than Codable so the field names are
    /// visible next to the page that reads them.
    var json: String {
        let fields: [String] = [
            "\"type\":\"status\"",
            "\"tc\":\(RemoteJSON.quoted(timecode))",
            "\"recording\":\(recording)",
            "\"capturing\":\(capturing)",
            "\"format\":\(RemoteJSON.quoted(format))",
            "\"take\":\(RemoteJSON.quoted(takeName))",
            "\"rating\":\(RemoteJSON.quoted(rating))",
            "\"diskGB\":\(RemoteJSON.number(diskFreeGB))",
            "\"markers\":\(markerCount)",
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// A command from the page. `hello` is the PIN handshake; the rest are the
/// four buttons.
enum RemoteCommand: String, Sendable, CaseIterable {
    case hello
    case rec
    case marker
    case good
    case bad
}

/// The parsed form of one client message: an action plus the PIN that came
/// with it. Every message carries the PIN — the socket is authenticated once,
/// but a command without the right PIN is refused even on an open socket, so a
/// page left on a phone that changed hands cannot press REC.
struct RemoteMessage: Equatable, Sendable {
    var command: RemoteCommand
    var pin: String

    /// Parse `{"action":"rec","pin":"1234"}`. Anything else is nil — the server
    /// answers with an error rather than guessing.
    static func parse(_ text: String) -> RemoteMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dictionary = object as? [String: Any],
              let action = dictionary["action"] as? String,
              let command = RemoteCommand(rawValue: action)
        else { return nil }
        return RemoteMessage(command: command,
                             pin: dictionary["pin"] as? String ?? "")
    }
}

/// JSON scalars, without pulling a whole encoder in for six fields.
enum RemoteJSON {
    /// A JSON string literal, escaped. Take names come from operator-typed
    /// fields, so a quote or a backslash in a project name has to survive the
    /// trip rather than break the page's parser.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    /// A finite JSON number. NaN and infinity are not JSON at all and would
    /// leave the page unable to parse the whole status.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        return String(format: "%.1f", value)
    }
}

/// The four-digit code shown in Settings.
enum RemotePIN {
    /// A fresh PIN. `SystemRandomNumberGenerator` rather than a counter or the
    /// clock: this is the only thing between the set network and the REC
    /// button, and 0000-style predictable codes are how that becomes nothing.
    static func generate() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    /// Whether `candidate` matches, compared in constant time.
    ///
    /// Four digits are brute-forceable by definition and the connection limit
    /// in `RemoteServer` is the real defence; this only keeps the comparison
    /// itself from being the cheaper attack.
    static func matches(_ candidate: String, expected: String) -> Bool {
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard !rhs.isEmpty else { return false }
        var difference = lhs.count ^ rhs.count
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? Int(lhs[index]) : 0
            let right = index < rhs.count ? Int(rhs[index]) : -1
            difference |= left ^ right
        }
        return difference == 0
    }
}
