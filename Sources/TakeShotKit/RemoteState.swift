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
    /// The last take that LANDED — the one the poster shows, the one the rating
    /// buttons act on. Kept apart from `takeName`, which mid-take is the name
    /// being written: the header on the phone is about the take in progress and
    /// the card under it is about the last take there is a frame of, and one
    /// field cannot be both without the card labelling last take's poster with
    /// this take's name.
    var lastTakeName: String = ""
    /// Identifies that take, so the page knows when to re-fetch the poster.
    ///
    /// The take's own id rather than a count of them: delete one and record
    /// another and the count is back where it was, which leaves a phone showing
    /// the poster of footage that is gone.
    var lastTakeID: String = ""
    /// "none" / "good" / "bad" — the last take's rating.
    var rating: String = "none"
    /// Free space on the record volume, GB. -1 when it cannot be read (the
    /// volume was pulled), which the page shows as a dash rather than as 0 GB.
    var diskFreeGB: Double = -1
    /// Markers where a marker press would land right now: the clip in the
    /// player in playback, the take in progress while recording, the last take
    /// otherwise — the same routing `addMarker()` itself uses. It used to count
    /// only the last take, so a marker placed in playback left the phone
    /// saying 0 (owner item 28).
    var markerCount: Int = 0
    /// "record" / "playback" — the viewer mode, so the page can adapt: per the
    /// owner, only REC is a static control, and a marker button offered over
    /// playback marks something the person holding the phone cannot see.
    var mode: String = "record"

    /// The wire form. Hand-built rather than Codable so the field names are
    /// visible next to the page that reads them.
    var json: String {
        let fields: [String] = [
            "\"type\":\"status\"",
            "\"tc\":\(RemoteJSON.quoted(timecode))",
            "\"recording\":\(recording)",
            "\"capturing\":\(capturing)",
            "\"mode\":\(RemoteJSON.quoted(mode))",
            "\"format\":\(RemoteJSON.quoted(format))",
            "\"take\":\(RemoteJSON.quoted(takeName))",
            "\"lastTake\":\(RemoteJSON.quoted(lastTakeName))",
            "\"lastTakeId\":\(RemoteJSON.quoted(lastTakeID))",
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
    /// Four digits are brute-forceable by definition; what costs an attacker is
    /// `RemotePINTarpit` holding every answer back once the guessing starts.
    /// This only keeps the comparison itself from being the cheaper attack —
    /// an early-exit compare leaks the code a digit at a time, and no delay on
    /// the answer helps with that.
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

/// What makes a four-digit code cost something to guess: a server-wide delay on
/// the ANSWER to every PIN check, once too many of them have failed lately.
///
/// The per-socket cap in `RemoteClient` never did this. Reconnecting is free, so
/// it only makes every fifth guess cost a fresh TCP connection — ten thousand
/// combinations against eight sockets at a time still fall in seconds on a set
/// network. The count that matters is the SERVER's, because no reconnect resets
/// it.
///
/// Two rules the delay lives or dies by:
///
/// - It is never a refusal. The unit holding the code is holding the phone that
///   starts the take, and a remote that locks out the right PIN because someone
///   else was guessing is a remote nobody switches on a second time. A correct
///   code is always accepted, just later.
/// - It is the same for a right code and a wrong one. A delay applied only to
///   failures is an oracle with a two-second clock on it, which is a better
///   oracle than the one it replaced.
///
/// A value type with the clock passed in: the decay is arithmetic, and testing
/// arithmetic should not cost a minute of wall clock.
struct RemotePINTarpit {
    /// Failures inside the window before answers start being held. Small enough
    /// to bite an enumeration in its first second; large enough that a unit
    /// mistyping the code on two phones never meets it.
    static let threshold = 6
    /// How long a failure is remembered. Attempts further apart than this never
    /// add up to anything, which is what "the delay decays" means here.
    static let window: TimeInterval = 60
    /// How long an answer waits while the tarpit is hot. Two seconds is barely
    /// noticeable behind a button press and turns the four-digit space from
    /// seconds of enumeration into most of an hour.
    static let delay: TimeInterval = 2

    /// Monotonic timestamps of recent failures, oldest first.
    ///
    /// Only the newest `threshold + 1` are kept: the question is ever only
    /// "were there MORE than `threshold` inside the window", and holding an
    /// unbounded list of them would let a flood the delay is meant to punish
    /// allocate freely on a machine that is recording.
    private var failures: [TimeInterval] = []

    /// Register one PIN verification and say how long its answer must wait.
    ///
    /// The delay is read from the state BEFORE this attempt is counted, so a
    /// right code and a wrong one presented at the same moment wait exactly as
    /// long — count first and the attempt that crosses the threshold would be
    /// delayed only if it happened to be the wrong one.
    mutating func attempt(failed: Bool, now: TimeInterval) -> TimeInterval {
        failures.removeAll { now - $0 >= Self.window }
        let held = failures.count > Self.threshold ? Self.delay : 0
        guard failed else { return held }
        failures.append(now)
        if failures.count > Self.threshold + 1 { failures.removeFirst() }
        return held
    }

    /// Failures still inside the window, capped as `failures` is. Read by the
    /// tests to know the burst landed; nothing branches on it.
    var pressure: Int { failures.count }
}
