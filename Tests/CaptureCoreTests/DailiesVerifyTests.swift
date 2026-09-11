import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **Did everything really render?** — `DailiesVerify` (owner: "ну и чтобы
/// какая-то у нас проверка типа как после копий была что все файлы точно
/// отрендерены как надо").
///
/// Each test breaks a finished folder one way and asks what the pass says,
/// because a verify that cannot tell the four faults apart is a verify that
/// tells an operator to re-render a day over a file somebody renamed.
@Suite(.timeLimit(.minutes(2))) struct DailiesVerifyTests {
    /// A folder with one real daily in it, the scratch it lives under, and
    /// the journal the run wrote.
    private struct Rendered {
        let folder: URL
        let root: URL
        let journal: DailiesJournal
    }

    private func rendered(frames: Int = 8, audio: Int = 0) async throws
        -> Rendered {
        let root = try DailiesRig.scratch()
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C01.mov"), frames: frames,
            audioChannels: audio)
        let folder = root.appendingPathComponent("Dailies")
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder, skipFinished: true)
        #expect(report.isFullySucceeded, "the fixture did not render")
        return Rendered(folder: folder, root: root,
                        journal: DailiesProgressJournal.read(in: folder))
    }

    private func verdicts(_ findings: [DailiesVerify.Finding])
        -> [DailiesVerify.Verdict] {
        findings.map(\.verdict)
    }

    /// A folder straight out of a run passes, and says nothing else.
    @Test func aFinishedFolderComesBackClean() async throws {
        let made = try await rendered()
        defer { try? FileManager.default.removeItem(at: made.root) }
        let findings = await DailiesVerify.check(made.journal, in: made.folder)
        #expect(verdicts(findings) == [.ok], """
            a folder this run just wrote came back \(findings)
            """)
        #expect(findings.allSatisfy { !$0.isFault })
    }

    /// The daily was moved away, or never copied to the shelf an assistant is
    /// looking at: the journal names it and the folder has not got it.
    @Test func aMissingDailyIsReported() async throws {
        let made = try await rendered()
        defer { try? FileManager.default.removeItem(at: made.root) }
        let entry = try #require(made.journal.entries.first)
        try FileManager.default.removeItem(
            at: made.folder.appendingPathComponent(entry.output))
        let findings = await DailiesVerify.check(made.journal, in: made.folder)
        #expect(verdicts(findings) == [.missing])
        #expect(findings.first?.isFault == true)
    }

    /// A file of the right name and the wrong size — a copy cut short, a disk
    /// that filled, a file somebody replaced. Caught before anything is opened,
    /// which is what makes a folder of forty cheap to check.
    @Test func aResizedDailyIsReported() async throws {
        let made = try await rendered()
        defer { try? FileManager.default.removeItem(at: made.root) }
        let entry = try #require(made.journal.entries.first)
        let url = made.folder.appendingPathComponent(entry.output)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 2).write(to: url)
        let findings = await DailiesVerify.check(made.journal, in: made.folder)
        #expect(verdicts(findings) == [.resized], """
            a half-written daily came back \(findings)
            """)
    }

    /// A file that is the size it should be and is not a movie at all: the
    /// size check cannot see this one, and the open is what does.
    @Test func anUnreadableDailyIsReported() async throws {
        let made = try await rendered()
        defer { try? FileManager.default.removeItem(at: made.root) }
        let entry = try #require(made.journal.entries.first)
        let url = made.folder.appendingPathComponent(entry.output)
        try Data(repeating: 0x5A, count: Int(entry.outputSize))
            .write(to: url)
        let findings = await DailiesVerify.check(made.journal, in: made.folder)
        #expect(verdicts(findings) == [.unreadable], """
            a file of noise at the right size came back \(findings)
            """)
    }

    /// **A daily that opens and is shorter than it was.** The one fault a size
    /// check cannot see on its own: this is a real movie, of the right size,
    /// of the wrong length — which is what a journal row from another render
    /// looks like, and what a truncation that happens to land on the same byte
    /// count would look like.
    @Test func aShortDailyIsReported() async throws {
        let made = try await rendered(frames: 8)
        defer { try? FileManager.default.removeItem(at: made.root) }
        var entry = try #require(made.journal.entries.first)
        let real: Double = try #require(entry.outputSeconds)
        entry.outputSeconds = real + 10
        let findings = await DailiesVerify.check(DailiesJournal(entries: [entry]),
                                                 in: made.folder)
        #expect(verdicts(findings) == [.short], """
            a daily ten seconds shorter than its row came back \(findings)
            """)
        #expect(findings.first?.detail.contains("was") == true)
    }

    /// …and one whose sound did not arrive. The row says two tracks, the file
    /// has one: a run whose sound folder was set and whose legs never opened.
    @Test func aDailyWithFewerSoundTracksIsReported() async throws {
        let made = try await rendered(audio: 2)
        defer { try? FileManager.default.removeItem(at: made.root) }
        var entry = try #require(made.journal.entries.first)
        #expect(entry.outputAudio == 1, """
            the fixture's own daily has \(entry.outputAudio ?? -1) sound tracks
            """)
        entry.outputAudio = 3
        let findings = await DailiesVerify.check(DailiesJournal(entries: [entry]),
                                                 in: made.folder)
        #expect(verdicts(findings) == [.silent])
    }

    /// A row from a build that recorded no length is reported as UNCHECKED and
    /// not as a fault: an old journal is not evidence of a bad file.
    @Test func aRowWithNoLengthIsUnchecked() async throws {
        let made = try await rendered()
        defer { try? FileManager.default.removeItem(at: made.root) }
        var entry = try #require(made.journal.entries.first)
        entry.outputSeconds = nil
        let findings = await DailiesVerify.check(DailiesJournal(entries: [entry]),
                                                 in: made.folder)
        #expect(verdicts(findings) == [.unchecked])
        #expect(findings.first?.isFault == false, """
            an unchecked row was counted as a fault
            """)
    }
}
