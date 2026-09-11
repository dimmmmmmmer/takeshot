import Foundation
import Testing

@testable import CaptureCore

/// **The folder's note about itself** — `DailiesJournal`, and the three asks
/// it answers (owner: "не рендерить уже отрендеренное — точно да", "чтоб если
/// софт вылетит можно было продолжить с того же места где упало", and a check
/// "что все файлы точно отрендерены как надо").
///
/// The rules here are all of the form "do NOT skip unless", because every way
/// of being unsure has to end in rendering: a run that renders something it
/// need not have costs an encode, and a run that skips something it should
/// have made costs the unit a daily nobody notices is missing until the
/// screening.
@Suite struct DailiesJournalTests {
    private func scratch() throws -> URL {
        let url = TestMedia.scratchDirectory("DailiesJournal")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ url: URL, bytes: Int) throws -> URL {
        try Data(repeating: 0x2A, count: bytes).write(to: url)
        return url
    }

    private func entry(source: URL, output: URL, recipe: String = "r1") throws
        -> DailiesJournal.Entry {
        let sourceFacts = try #require(DailiesJournal.facts(of: source))
        let outputFacts = try #require(DailiesJournal.facts(of: output))
        return DailiesJournal.Entry(
            source: source.lastPathComponent, sourceSize: sourceFacts.size,
            sourceModified: sourceFacts.modified, recipe: recipe,
            output: output.lastPathComponent, outputSize: outputFacts.size,
            finishedAt: Date())
    }

    /// The whole point, in one: a source that has been rendered, with this
    /// recipe, whose daily is still there at the size it was, is finished.
    @Test func aFinishedItemIsRecognisedByItsSourceAndItsRecipe() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root.appendingPathComponent("A001C01.mov"),
                              bytes: 2048)
        let output = try file(root.appendingPathComponent("A001C01_DAILY.mov"),
                              bytes: 512)
        var journal = DailiesJournal()
        journal.record(try entry(source: source, output: output))

        #expect(journal.finished(source: source, recipe: "r1", in: root)
            == output)
        #expect(journal.finished(source: source, recipe: "r2", in: root) == nil,
                "a different recipe is a different deliverable")
    }

    /// **A source that has changed is not the source that was rendered.** A
    /// card re-offloaded over the same names, a clip re-exported from the
    /// camera — either is new footage under an old name, and the daily beside
    /// it is of something else.
    @Test func aChangedSourceIsRenderedAgain() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root.appendingPathComponent("A001C02.mov"),
                              bytes: 2048)
        let output = try file(root.appendingPathComponent("A001C02_DAILY.mov"),
                              bytes: 512)
        var journal = DailiesJournal()
        journal.record(try entry(source: source, output: output))
        try #require(journal.finished(source: source, recipe: "r1",
                                      in: root) != nil)

        try file(source, bytes: 4096)
        #expect(journal.finished(source: source, recipe: "r1", in: root) == nil,
                "the source grew by 2 kB and the old daily was accepted")
    }

    /// …and a daily that is GONE, or that is not the file the note describes,
    /// is rendered again. The note is a claim about a disk, and the disk is
    /// what answers.
    @Test func aMissingOrChangedDailyIsRenderedAgain() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root.appendingPathComponent("A001C03.mov"),
                              bytes: 2048)
        let output = try file(root.appendingPathComponent("A001C03_DAILY.mov"),
                              bytes: 512)
        var journal = DailiesJournal()
        journal.record(try entry(source: source, output: output))

        try file(output, bytes: 64)
        #expect(journal.finished(source: source, recipe: "r1", in: root) == nil,
                "the daily is a different size and was accepted anyway")
        try FileManager.default.removeItem(at: output)
        #expect(journal.finished(source: source, recipe: "r1", in: root) == nil,
                "the daily is not there at all and was accepted anyway")
    }

    /// One row per source per recipe: a re-render replaces the row instead of
    /// growing a second one, or a day's journal is a day's worth of history
    /// nobody asked for.
    @Test func recordingTheSameSourceTwiceReplacesItsRow() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root.appendingPathComponent("A001C04.mov"),
                              bytes: 1024)
        let output = try file(root.appendingPathComponent("A001C04_DAILY.mov"),
                              bytes: 256)
        var journal = DailiesJournal()
        journal.record(try entry(source: source, output: output))
        journal.record(try entry(source: source, output: output))
        #expect(journal.entries.count == 1)
        journal.record(try entry(source: source, output: output, recipe: "r2"))
        #expect(journal.entries.count == 2,
                "a second recipe is a second daily, not a replacement")
    }

    /// It survives the round trip to disk, dates and all — which is the only
    /// reason it is worth writing.
    @Test func theJournalComesBackOffDisk() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root.appendingPathComponent("A001C05.mov"),
                              bytes: 1024)
        let output = try file(root.appendingPathComponent("A001C05_DAILY.mov"),
                              bytes: 256)
        var journal = DailiesJournal()
        journal.record(try entry(source: source, output: output))
        try DailiesProgressJournal.write(journal, into: root)

        let read = DailiesProgressJournal.read(in: root)
        #expect(read.entries.count == 1)
        #expect(read.finished(source: source, recipe: "r1", in: root) == output,
                "the journal came back but no longer recognises its own row")
        #expect(DailiesProgressJournal.read(in: root.appendingPathComponent("no"))
            .entries.isEmpty, "a folder with no journal is not an error")
    }

    /// **The recipe changes when the deliverable does, and not otherwise.**
    /// A fingerprint that moved for something nobody can see would re-render a
    /// show; one that stood still through a burn-in change would ship
    /// yesterday's arrangement.
    @Test func theRecipeFollowsWhatReachesThePicture() {
        var burnins = DailiesBurnins()
        let base = DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
        #expect(base == DailiesRecipe.fingerprint(burnins: burnins,
                                                  codec: .h264),
                "the same run fingerprinted differently twice")
        #expect(DailiesRecipe.fingerprint(burnins: burnins, codec: .proResProxy)
            != base, "the codec is not in the recipe")
        burnins.date = true
        #expect(DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
            != base, "a burn-in switch is not in the recipe")
        burnins = DailiesBurnins()
        burnins.customText = "FOR REVIEW"
        #expect(DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
            != base, "the custom line's TEXT is not in the recipe")
        #expect(DailiesRecipe.fingerprint(burnins: DailiesBurnins(),
                                          codec: .h264, desqueeze: 2) != base,
                "the baked desqueeze is not in the recipe")
    }
}
