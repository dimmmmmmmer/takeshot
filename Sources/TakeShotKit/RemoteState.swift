import CaptureCore
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
    /// One entry per camera, main first, in the order the multiview page's
    /// binary frames index them. The REC light on each tile is this state,
    /// not the top-level `recording` — in multicam the boards record apart.
    var cameras: [CameraState] = []

    /// A camera as the multiview tile shows it: its label and whether ITS
    /// pipeline is writing right now.
    struct CameraState: Equatable, Sendable {
        var name: String
        var recording: Bool
    }

    /// The wire form. Hand-built rather than Codable so the field names are
    /// visible next to the page that reads them.
    var json: String {
        let tiles = cameras.map {
            "{\"name\":\(RemoteJSON.quoted($0.name))"
                + ",\"recording\":\($0.recording)}"
        }
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
            "\"cameras\":[" + tiles.joined(separator: ",") + "]",
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// The script supervisor's take log: every take the panel lists, with the
/// fields a scripty logs — pushed as one more message `type` on the same
/// socket the status rides, never on a channel of its own.
struct RemoteTakeLog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The take's own id, so an edit from the page lands on the row it was
        /// typed against even after another take finalizes under it.
        var id: String
        var name: String
        /// Start timecode as text; empty when the take carried none.
        var timecode: String
        var durationSeconds: Double
        /// "none" / "good" / "bad" — the same three states as the panel.
        var rating: String
        var comment: String
        /// The creative fields the scripty owns. Scene and shot as typed; the
        /// take as text, because an empty string is how "not logged" travels
        /// and a number has no way to say it.
        var scene: String = ""
        var shot: String = ""
        var take: String = ""
        /// Where this row's frame comes from — the image route with the take
        /// named on it, PIN excluded. The page appends the code it is holding.
        ///
        /// Carried in the payload rather than assembled on the page: the page
        /// would otherwise be the fourth place that knows the route's shape,
        /// and the failure mode of a mismatch is a log of broken thumbnails
        /// that looks exactly like footage the app cannot read.
        var poster: String = ""

        /// The reference for a take id — the one place the query is built.
        static func posterReference(takeID: String) -> String {
            RemotePage.posterPath + "?" + RemotePage.posterTakeParameter + "="
                + takeID
        }
    }

    /// Oldest first, matching the app's take list; the page renders newest on
    /// top by walking it backwards.
    var entries: [Entry] = []

    /// The wire form. Hand-built like `RemoteStatus.json`, and through the same
    /// escapes: names and comments are operator- and scripty-typed text.
    var json: String {
        let rows = entries.map { entry in
            "{\"id\":\(RemoteJSON.quoted(entry.id))"
                + ",\"name\":\(RemoteJSON.quoted(entry.name))"
                + ",\"tc\":\(RemoteJSON.quoted(entry.timecode))"
                + ",\"dur\":\(RemoteJSON.number(entry.durationSeconds))"
                + ",\"rating\":\(RemoteJSON.quoted(entry.rating))"
                + ",\"comment\":\(RemoteJSON.quoted(entry.comment))"
                + ",\"scene\":\(RemoteJSON.quoted(entry.scene))"
                + ",\"shot\":\(RemoteJSON.quoted(entry.shot))"
                + ",\"take\":\(RemoteJSON.quoted(entry.take))"
                + ",\"poster\":\(RemoteJSON.quoted(entry.poster))}"
        }
        return "{\"type\":\"takes\",\"takes\":["
            + rows.joined(separator: ",") + "]}"
    }
}

/// A command from the page. `hello` is the PIN handshake; `rec`/`marker`/
/// `good`/`bad` are the operator page's four buttons; `rate` and `comment` are
/// the script page's per-take edits.
enum RemoteCommand: Equatable, Sendable {
    case hello
    case rec
    case marker
    case good
    case bad
    /// Set one take's rating to an explicit state. The page sends the target
    /// state rather than "toggle", so a tap raced against an edit made in the
    /// app lands on a named rating instead of flipping whatever is newest.
    case rate(takeID: String, rating: TakeRating)
    /// Replace one take's free-text comment.
    case comment(takeID: String, text: String)
    /// Replace one take's slate — scene, shot and the take number inside the
    /// scene. All three at once rather than three commands: the page commits
    /// the row's slate as a unit, and three messages racing each other would
    /// let a half-applied slate be pushed back between them.
    case slate(takeID: String, slate: SlateMetadata)
    /// The multiview page asked for (or gave up) the camera-frame stream.
    /// Settled by the server itself — a per-connection subscription, not an
    /// app command — so it is never dispatched to the controller.
    case multiview(on: Bool)

    /// The wire action plus whatever arguments it carries. nil for anything
    /// malformed — an unknown rating word must not be read as "clear it".
    ///
    /// The bare actions here, the ones that carry arguments below: reading
    /// the argument rules inline put this over the project's complexity
    /// ceiling, which is the ceiling doing its job.
    static func parse(action: String,
                      in dictionary: [String: Any]) -> RemoteCommand? {
        switch action {
        case "hello": return .hello
        case "rec": return .rec
        case "marker": return .marker
        case "good": return .good
        case "bad": return .bad
        default: return parseWithArguments(action: action, in: dictionary)
        }
    }

    private static func parseWithArguments(
        action: String, in dictionary: [String: Any]) -> RemoteCommand? {
        switch action {
        case "rate":
            guard let id = dictionary["id"] as? String, !id.isEmpty,
                  let rating = TakeRating(
                      rawValue: dictionary["rating"] as? String ?? "")
            else { return nil }
            return .rate(takeID: id, rating: rating)
        case "comment":
            guard let id = dictionary["id"] as? String, !id.isEmpty,
                  let text = dictionary["text"] as? String
            else { return nil }
            return .comment(takeID: id, text: text)
        case "slate":
            // Strict about the id and about the three fields being present:
            // a message missing one of them would silently CLEAR it, which is
            // how a scripty loses a scene number they typed an hour ago.
            guard let id = dictionary["id"] as? String, !id.isEmpty,
                  let scene = dictionary["scene"] as? String,
                  let shot = dictionary["shot"] as? String,
                  let take = dictionary["take"] as? String
            else { return nil }
            return .slate(takeID: id,
                          slate: SlateMetadata(scene: scene, shot: shot,
                                               take: slateTake(take)))
        case "multiview":
            // Strict, like `rate`: a missing flag must not be read as "on".
            guard let on = dictionary["on"] as? Bool else { return nil }
            return .multiview(on: on)
        default:
            return nil
        }
    }

    /// The slate's take number off the wire. Empty — and anything that is not
    /// a positive whole number — means "not logged", which is a state the page
    /// can express by clearing the field.
    private static func slateTake(_ text: String) -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              value > 0 else { return 0 }
        return value
    }
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
              let command = RemoteCommand.parse(action: action, in: dictionary)
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
