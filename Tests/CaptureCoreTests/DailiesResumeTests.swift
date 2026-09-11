import Foundation
import Testing

@testable import CaptureCore

/// **A day is rendered once** — the engine's half of the journal (owner: "не
/// рендерить уже отрендеренное — точно да", "чтоб если софт вылетит можно было
/// продолжить с того же места где упало").
///
/// Two things are being pinned. A second run over a folder that already holds
/// the dailies does nothing and SAYS it did nothing; and the note that makes
/// that possible is written after each item rather than at the end, which is
/// the only version of it that survives the app being killed.
@Suite(.timeLimit(.minutes(2))) struct DailiesResumeTests {
    private func run(_ items: [DailiesItem], into folder: URL,
                     burnins: DailiesBurnins = DailiesRig.noBurnins,
                     skipFinished: Bool = true) async -> DailiesReport {
        await DailiesEngine.run(items: items, burnins: burnins, into: folder,
                                skipFinished: skipFinished)
    }

    @Test func aSecondRunSkipsWhatIsAlreadyThere() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C01.mov"), frames: 8)
        let folder = root.appendingPathComponent("Dailies")
        let item = DailiesRig.item(for: source)

        let first = await run([item], into: folder)
        #expect(first.rendered.count == 1, "the first run made nothing")
        let made: URL = try #require(first.items.first?.output)

        let second = await run([item], into: folder)
        #expect(second.skipped.count == 1, """
            the second run rendered \(second.rendered.count) item(s) over a \
            folder that already held them
            """)
        #expect(second.rendered.isEmpty)
        #expect(second.items.first?.output == made,
                "the skipped item points at some other file")
        #expect(second.isFullySucceeded, """
            a skipped item is a succeeded item — the daily the operator asked \
            for is on the disk
            """)
    }

    /// …and with the switch off it renders again, which is what an operator
    /// asking for a re-render means. The app's no-silent-overwrite rule stands
    /// either way: the new one is `_2`, the old one is untouched.
    @Test func theSwitchOffRendersItAgainBesideTheFirst() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C02.mov"), frames: 8)
        let folder = root.appendingPathComponent("Dailies")
        let item = DailiesRig.item(for: source)

        let first = await run([item], into: folder)
        let made: URL = try #require(first.items.first?.output)
        let again = await run([item], into: folder, skipFinished: false)
        let second: URL = try #require(again.items.first?.output)
        #expect(again.skipped.isEmpty)
        #expect(second != made)
        #expect(second.lastPathComponent.contains("_2"), """
            the re-render landed on \(second.lastPathComponent)
            """)
        #expect(FileManager.default.fileExists(atPath: made.path),
                "the first daily was overwritten")
    }

    /// **A different arrangement is a different daily.** The burn-ins moved,
    /// so the file on disk is not the file this run would make, and skipping
    /// it would quietly ship yesterday's layout to the whole unit.
    @Test func changingTheBurnInsRendersItAgain() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C03.mov"), frames: 8)
        let folder = root.appendingPathComponent("Dailies")
        let item = DailiesRig.item(for: source)

        _ = await run([item], into: folder)
        var changed = DailiesRig.noBurnins
        changed.customText = "FOR REVIEW"
        let second = await run([item], into: folder, burnins: changed)
        #expect(second.skipped.isEmpty, """
            the run skipped an item whose burn-ins had changed
            """)
        #expect(second.rendered.count == 1)
    }

    /// **The note is on disk after the FIRST item, not at the end of the run.**
    ///
    /// That is the whole of the crash-resume: a run killed in the middle has
    /// written the dailies it finished and the record of them, so the next one
    /// starts where it stopped. Measured by rendering two items and reading
    /// the folder's journal — both rows are there, and each names the file it
    /// made.
    @Test func theJournalNamesEveryFinishedItem() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C04.mov"), frames: 6)
        let second = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C05.mov"), frames: 6)
        let folder = root.appendingPathComponent("Dailies")
        let report = await run([DailiesRig.item(for: first),
                                DailiesRig.item(for: second)], into: folder)
        #expect(report.rendered.count == 2)

        let journal = DailiesProgressJournal.read(in: folder)
        #expect(journal.entries.count == 2, """
            the folder's journal holds \(journal.entries.count) rows for two \
            finished dailies
            """)
        for source in [first, second] {
            let row = journal.entries.first {
                $0.source == source.lastPathComponent
            }
            let entry: DailiesJournal.Entry = try #require(row, """
                nothing in the journal names \(source.lastPathComponent)
                """)
            #expect(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(entry.output).path), """
                the journal names \(entry.output), which is not in the folder
                """)
            #expect(entry.outputSize > 0)
        }
    }

    /// **A new name is a new file, even with everything else the same** — the
    /// affixes around a take's name are the operator's and are not in the
    /// recipe, so without the requested NAME in the identity a day re-rendered
    /// under a new suffix matched every entry it had, skipped every item, and
    /// produced nothing at all under the name that was asked for.
    @Test func renamingTheOutputRendersItAgain() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C06.mov"), frames: 6)
        let folder = root.appendingPathComponent("Dailies")
        var item = DailiesRig.item(for: source)

        let first = await run([item], into: folder)
        #expect(first.rendered.count == 1)

        item.outputName = "A001C06_REVIEW"
        let second = await run([item], into: folder)
        #expect(second.skipped.isEmpty, """
            the run skipped an item whose output name had changed
            """)
        let made: URL = try #require(second.items.first?.output)
        #expect(made.lastPathComponent == "A001C06_REVIEW.mov", """
            the re-render landed on \(made.lastPathComponent)
            """)
        // …and asking for the FIRST name again still skips: both rows are in
        // the journal, one per name.
        item.outputName = "A001C06_DAILY"
        let third = await run([item], into: folder)
        #expect(third.skipped.count == 1, """
            the original name was rendered a second time
            """)
    }
}
