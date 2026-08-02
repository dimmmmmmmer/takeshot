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
    /// Shot / setup / slate letter inside the scene: "A", "B", "2C". Called
    /// "shot" rather than "slate" because that is the ALE and Resolve column
    /// name, and the exporters have to line up with those.
    public var shot: String
    /// Take number WITHIN the scene; 0 — not logged.
    ///
    /// Not the clip counter. A scene's takes restart at 1 while the file
    /// numbering runs on for the whole roll, and the two disagreeing is the
    /// normal case, not an error.
    public var take: Int

    public static let empty = SlateMetadata()

    public init(scene: String = "", shot: String = "", take: Int = 0) {
        self.scene = scene
        self.shot = shot
        self.take = take
    }

    /// Nothing was logged — no key is written to the file and no row to the
    /// sidecar. An empty slate must not leave junk metadata behind.
    public var isEmpty: Bool {
        scene.isEmpty && shot.isEmpty && take <= 0
    }

    /// The slate spelled out for a human reading the file's metadata in an
    /// NLE: "Scene 12A / Shot B / Take 3". English, like every other value
    /// CaptureCore writes into a machine-read file — the reader is an editor
    /// in post, not the operator whose UI language this app follows.
    public var summary: String {
        var parts: [String] = []
        if !scene.isEmpty { parts.append("Scene \(scene)") }
        if !shot.isEmpty { parts.append("Shot \(shot)") }
        if take > 0 { parts.append("Take \(take)") }
        return parts.joined(separator: " / ")
    }

    /// The slate as it fits on one line of paperwork: "12A/B T3". No words at
    /// all, so the shift report and the contact sheet can print it in either
    /// language without translating a data field.
    public var compact: String {
        let slate = [scene, shot].filter { !$0.isEmpty }.joined(separator: "/")
        let takePart = take > 0 ? "T\(take)" : ""
        return [slate, takePart].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
