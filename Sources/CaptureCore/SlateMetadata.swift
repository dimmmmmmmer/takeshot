import Foundation

/// The CREATIVE metadata of a take — what a slate carries and a technical
/// filename cannot: which scene, which shot/setup, and which take of it.
///
/// Deliberately separate from the naming inputs (prefix/cam/roll/clip). Those
/// describe the FILE and are chosen by the DIT; these describe what was shot
/// and are chosen by the script supervisor. Keeping them apart is also what
/// lets the take number restart per scene while the clip counter keeps rising.
///
/// This is the part that goes INSIDE the .mov (see `TakeWriter`): everything a
/// take picks up afterwards — rating, comment, description — is review state
/// and stays in the sidecars, because a finalized recording is never rewritten.
public struct SlateMetadata: Equatable, Sendable {
    /// Scene as the script supervisor writes it: "12", "12A", "104".
    public var scene: String
    /// Shot NUMBER inside the scene; 0 — not logged.
    ///
    /// A number and not a letter, which it used to be. The letter was the
    /// American setup convention — scene 12, setup A, slated "12A" — and it
    /// arrived here because "shot" is the ALE and Resolve column name and that
    /// column holds text. But the slate this app is filled in against is read
    /// out as scene, shot, take, all three of them numbers (owner: "даже
    /// говорят же сцена 1 кадр 1 дубль 1. откуда там буквы взялись то?").
    ///
    /// Scene stays a STRING because a scene number genuinely is not one: "12A"
    /// and "104" are both what a script supervisor writes. Only this field was
    /// carrying a convention nobody here uses.
    ///
    /// It is still written into the file and the sidecars as its decimal text,
    /// so the frozen CSV schema and the ALE column are untouched — what changed
    /// is what this app will let an operator put there.
    public var shot: Int
    /// Take number WITHIN the scene; 0 — not logged.
    ///
    /// Not the clip counter. A scene's takes restart at 1 while the file
    /// numbering runs on for the whole roll, and the two disagreeing is the
    /// normal case, not an error.
    public var take: Int

    /// The shot as it is WRITTEN — into the file's metadata, the CSV column,
    /// the ALE. Empty when nothing was logged, so a blank cell stays blank
    /// rather than becoming a zero that reads like a real shot number.
    ///
    /// One spelling for every writer: the number lives here and the text form
    /// is derived from it, so a column cannot come to disagree with the take
    /// panel about what shot 0 means.
    public var shotText: String { shot > 0 ? String(shot) : "" }

    public static let empty = SlateMetadata()

    public init(scene: String = "", shot: Int = 0, take: Int = 0) {
        self.scene = scene
        self.shot = shot
        self.take = take
    }

    /// Nothing was logged — no key is written to the file and no row to the
    /// sidecar. An empty slate must not leave junk metadata behind.
    public var isEmpty: Bool {
        scene.isEmpty && shot <= 0 && take <= 0
    }

    /// The slate spelled out for a human reading the file's metadata in an
    /// NLE: "Scene 12A / Shot 1 / Take 3". English, like every other value
    /// CaptureCore writes into a machine-read file — the reader is an editor
    /// in post, not the operator whose UI language this app follows.
    public var summary: String {
        var parts: [String] = []
        if !scene.isEmpty { parts.append("Scene \(scene)") }
        if shot > 0 { parts.append("Shot \(shot)") }
        if take > 0 { parts.append("Take \(take)") }
        return parts.joined(separator: " / ")
    }

    /// The slate as it fits on one line of paperwork: "12A/1 T3". No words at
    /// all, so the shift report and the contact sheet can print it in either
    /// language without translating a data field.
    public var compact: String {
        let slate = [scene, shot > 0 ? String(shot) : ""]
            .filter { !$0.isEmpty }.joined(separator: "/")
        let takePart = take > 0 ? "T\(take)" : ""
        return [slate, takePart].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
