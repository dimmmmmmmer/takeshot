import Foundation

import CaptureCore

/// The values an operator can actually get into a field, in one place.
///
/// Every deliverable this app writes is built by pasting operator text into a
/// format with its own escaping rules, and the formats disagree about which
/// characters are dangerous. So the corpus is stated once and each exporter's
/// suite runs the whole of it through its own writer and, where the app can
/// read the file back, its own parser.
///
/// The comment field is a `TextEditor` with no input filter at all and the
/// naming template is a plain `TextField`, so everything here is reachable by
/// typing or pasting. `NameField` does filter the slate and naming fields, but
/// only against control characters — U+2028, which is what a paste out of Word
/// or a browser carries, is a `Zl` and goes straight through.
enum AwkwardText {
    /// Each case is named, so a failure says which character did it.
    static let all: [(name: String, value: String)] = [
        ("a comma", "a,b"),
        ("a double quote", "he said \"go\""),
        ("a line feed", "one\ntwo"),
        ("a carriage return", "one\rtwo"),
        ("a CRLF", "one\r\ntwo"),
        ("U+2028 LINE SEPARATOR", "one\u{2028}two"),
        ("U+2029 PARAGRAPH SEPARATOR", "one\u{2029}two"),
        ("U+0085 NEXT LINE", "one\u{85}two"),
        ("a vertical tab", "one\u{0B}two"),
        ("a form feed", "one\u{0C}two"),
        ("a semicolon", "a;b"),
        ("a tab", "a\tb"),
        ("a leading equals", "=1+1"),
        ("a leading plus", "+1"),
        ("a leading minus", "-1 stop"),
        ("a leading at", "@camera"),
        ("emoji", "ok \u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}"),
        ("a right-to-left mark", "a\u{200F}b"),
        ("a very long run", String(repeating: "X", count: 300)),
        ("nothing at all", ""),
        ("only spaces", "   "),
        ("a NUL", "a\u{0}b"),
        ("a bell", "a\u{07}b"),
        ("a DEL", "a\u{7F}b"),
        ("XML metacharacters", "A&B <take 2> \"x\" 'y'"),
        ("two dots", ".."),
        ("a leading dot", ".hidden"),
        ("a path separator", "a/b"),
        ("a colon", "a:b"),
    ]

    /// The corpus with the empty string dropped, for the places where an empty
    /// value means "there is nothing here" rather than a value to preserve.
    static var nonEmpty: [(name: String, value: String)] {
        all.filter { !$0.value.isEmpty }
    }

    /// The corpus minus the values that cannot occur in a FILE NAME, for the
    /// tests that put a value there rather than in a field.
    ///
    /// Only the NUL is dropped, and not to make a test pass. A NUL is the one
    /// byte a POSIX path cannot contain, `NameField` refuses control characters
    /// at entry, and a folder scan cannot hand one back — so in this position it
    /// is not a value an operator can reach.
    ///
    /// What it DID reach was Foundation. `URL(fileURLWithPath:)` percent-encodes
    /// the NUL on macOS 26, so `lastPathComponent` comes back as the nine safe
    /// characters `a%00b.mov`; the older Foundation on the CI runner does not
    /// agree, the name that reached the row was a different string, and three
    /// tests failed on a lookup by name. They were measuring Foundation's URL
    /// escaping, not this app's CSV escaping.
    ///
    /// The NUL stays in `all`, because a comment, scene or roll CAN carry one —
    /// a restored settings blob or a remote message is not filtered by a text
    /// field — and those tests are the ones that should be asking about it.
    static var pathSafe: [(name: String, value: String)] {
        all.filter { !$0.value.unicodeScalars.contains("\u{0}") }
    }

    /// Both restrictions at once, for a test that puts the value in a file name
    /// AND needs a value to compare (see `pathSafe` and `nonEmpty`).
    static var pathSafeNonEmpty: [(name: String, value: String)] {
        pathSafe.filter { !$0.value.isEmpty }
    }

    /// A take carrying `value` wherever the caller puts it.
    static func take(named name: String = "clip.mov", roll: String = "R001",
                     comment: String = "", scene: String = "",
                     shot: String = "", logDescription: String = "",
                     note: String? = nil) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/takes/\(name)"),
                        scene: scene, roll: roll, takeNumber: 1,
                        startTimecode: Timecode(hours: 10, minutes: 0,
                                                seconds: 0, frames: 0, fps: 25),
                        durationSeconds: 2,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.slate.shot = shot
        take.comment = comment
        take.logDescription = logDescription
        if let note { take.markers = [TakeMarker(seconds: 1, note: note)] }
        return take
    }
}
