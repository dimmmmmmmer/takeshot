@preconcurrency import AVFoundation
import Foundation

/// **Is every daily really there, and really finished?** (owner: "ну и чтобы
/// какая-то у нас проверка типа как после копий была что все файлы точно
/// отрендерены как надо".)
///
/// **It is not the offload's verify and cannot be.** That one re-hashes a copy
/// against the card it came from: there are two files and they are supposed to
/// be identical. A daily is GENERATED — nothing on disk is supposed to equal
/// it — so the only thing to hold it against is what it was when it was
/// written, which is what the journal records after every item
/// (`DailiesJournal.Entry`).
///
/// So the four questions are these, in the order a file fails them:
///
/// - is it THERE at all;
/// - is it the SIZE it was written at (a copy cut short, a disk that filled);
/// - does it OPEN, with a video track in it (a file finished by nothing, or
///   damaged since);
/// - is it as LONG as it was, and with the sound tracks it had (a daily that
///   was truncated, or one whose sound never arrived).
///
/// What it deliberately does NOT do is look at the picture. "Rendered as it
/// should be" in the sense of the burn-ins being in the right corner is what
/// the sheet's own preview is for, and a pass that decoded every frame of a
/// day would cost as much as making the dailies again.
public enum DailiesVerify {
    /// What one daily came back as. Beside `Finding` rather than inside it
    /// because three levels of nesting is a name nobody can write.
    public enum Verdict: String, Sendable, Equatable {
        /// There, the size it was, opens, as long as it was.
        case ok
        /// The journal names a file the folder has not got.
        case missing
        /// There, and not the size it was written at.
        case resized
        /// It will not open, or has no picture in it.
        case unreadable
        /// It opens and is shorter than it was written to be.
        case short
        /// It opens and has fewer sound tracks than it was written with.
        case silent
        /// Written by a build that recorded no length — nothing to check it
        /// against, and saying so is the honest answer.
        case unchecked
    }

    /// One daily, checked.
    public struct Finding: Sendable, Equatable {
        public var output: String
        public var verdict: Verdict
        /// One line an operator can act on. English: this is a diagnostic, and
        /// the app translates the VERDICT where it shows it.
        public var detail: String

        public init(output: String, verdict: Verdict, detail: String = "") {
            self.output = output
            self.verdict = verdict
            self.detail = detail
        }

        public var isFault: Bool { verdict != .ok && verdict != .unchecked }
    }

    /// Half a second: a container states its duration in its own timescale and
    /// an encoder finishes on a frame boundary, so two readings of one file
    /// differ in the third decimal. A daily that is short by half a second is
    /// short by more than a dozen frames at any rate on set.
    public static let lengthTolerance = 0.5

    /// Check every daily the journal names.
    ///
    /// The journal is the list, and that is a decision worth stating: a folder
    /// also holds whatever else somebody put in it, and a pass that walked the
    /// DIRECTORY would report an operator's own copy of a reference clip as an
    /// unknown daily. What this answers is "did the runs that wrote this
    /// folder produce what they said they produced".
    public static func check(_ journal: DailiesJournal,
                             in folder: URL) async -> [Finding] {
        var findings: [Finding] = []
        for entry in journal.entries {
            findings.append(await check(entry, in: folder))
        }
        return findings
    }

    static func check(_ entry: DailiesJournal.Entry,
                      in folder: URL) async -> Finding {
        let url = folder.appendingPathComponent(entry.output)
        guard let facts = DailiesJournal.facts(of: url) else {
            return Finding(output: entry.output, verdict: .missing,
                           detail: "not in \(folder.lastPathComponent)")
        }
        guard facts.size == entry.outputSize else {
            return Finding(output: entry.output, verdict: .resized,
                           detail: "\(facts.size) bytes, was \(entry.outputSize)")
        }
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.tracks(ofType: .video),
              !video.isEmpty,
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite else {
            return Finding(output: entry.output, verdict: .unreadable,
                           detail: "no picture track")
        }
        guard let expected = entry.outputSeconds else {
            return Finding(output: entry.output, verdict: .unchecked,
                           detail: "written before the length was recorded")
        }
        guard duration >= expected - lengthTolerance else {
            return Finding(
                output: entry.output, verdict: .short,
                detail: String(format: "%.2fs, was %.2fs", duration, expected))
        }
        let audio = (try? await asset.tracks(ofType: .audio))?.count ?? 0
        guard audio >= (entry.outputAudio ?? 0) else {
            return Finding(
                output: entry.output, verdict: .silent,
                detail: "\(audio) sound track(s), was \(entry.outputAudio ?? 0)")
        }
        return Finding(output: entry.output, verdict: .ok)
    }
}
