import CaptureCore
import Foundation

/// **What one file in the queue is called, and what it says about itself.**
///
/// Pure functions over a take or a URL and the settings — nothing here reads
/// the model's state, which is why it is a file of its own: the model reached
/// the type-length ceiling when it learned about folders, and the half that
/// moved is the half that was never about state.
extension DailiesQueueModel {
    /// The name one take's daily will be written under, without the extension
    /// — what the sheet shows as a live example.
    func outputName(for takeName: String) -> String {
        Self.outputName(take: takeName, prefix: namePrefix, suffix: nameSuffix)
    }

    /// **The whole naming rule, in one place.**
    ///
    /// `NameField.prefix.normalized` is what the operator's typing already
    /// goes through in the fields, but the RESULT is what reaches
    /// `appendingPathComponent`, and nothing on that path sanitized it before:
    /// a prefix of "../" or a name that came out empty had a filesystem answer
    /// and no app answer. So the joined name is normalized again here.
    ///
    /// Two things `normalized` alone does not do, both found by the test that
    /// tried them:
    ///
    /// - **Leading dots are dropped.** `normalized` removes the separators, so
    ///   "../../" cannot climb out of the dailies folder — but it leaves the
    ///   dots, and a name beginning with one is a file macOS hides. A daily
    ///   the operator cannot see in Finder is worse than a daily with an odd
    ///   name.
    /// - **An empty result falls back to the take's own name.** An empty path
    ///   component handed to `appendingPathComponent` names the dailies
    ///   FOLDER, and a daily with no name is not a daily.
    static func outputName(take: String, prefix: String,
                           suffix: String) -> String {
        let joined = NameField.prefix.normalized(prefix + take + suffix)
        let visible = String(joined.drop(while: { $0 == "." }))
        return visible.isEmpty ? take : visible
    }

    /// A file off a card as a queue item.
    ///
    /// What a foreign clip can say about itself is its NAME and its date; the
    /// timecode comes from the file's own track if it has one (the engine
    /// reads it) and there is no start-TC fallback to offer, because a
    /// camera's clip carries no slate this app wrote.
    static func item(for url: URL, settings: CaptureSettings,
                     prefix: String = "", suffix: String = "_DAILY")
        -> DailiesItem {
        let name = url.deletingPathExtension().lastPathComponent
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let modified = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return DailiesItem(
            source: url,
            outputName: outputName(take: name, prefix: prefix, suffix: suffix),
            clipName: name,
            projectLine: settings.naming.projectName,
            dateText: modified.map(stamp.string(from:)) ?? "",
            startTimecode: nil)
    }

    // MARK: - what the engine is told about one take

    /// A take as a queue item: the file, the `<name>_DAILY` output, and the
    /// burn-in facts composed from the settings that own them.
    static func item(for take: Take, settings: CaptureSettings,
                     prefix: String = "", suffix: String = "_DAILY")
        -> DailiesItem {
        // **The project alone.** It used to be "PROJECT · A001" — the camera
        // and the roll appended — and the roll is already in the file name
        // this run writes (owner: "из места где проект убери подпись ролла. он
        // же в названии файла дописывается и так"). A burn-in that repeats
        // what the name says spends a strip on nothing.
        let projectLine = settings.naming.projectName
        // ISO date, POSIX locale: a burn-in is read by post in another
        // country, and "03/04" means two different days to two of them.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return DailiesItem(
            source: take.url,
            outputName: outputName(take: take.displayName, prefix: prefix,
                                   suffix: suffix),
            clipName: take.displayName,
            projectLine: projectLine,
            dateText: stamp.string(from: take.recordedAt),
            startTimecode: take.startTimecode,
            // The flags become the proxy's chapters. Straight off the take —
            // they are already offsets into this very file.
            markers: take.markers)
    }
}
