import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **Where the dailies come from and where they go.**
///
/// The face the owner opened this round for: "дейлики нужны из исходников…
/// вероятно даже несколько источников, как в оффлоаде" and "и так же несколько
/// источников дестинейшна".
@Suite @MainActor struct ViewDailiesFilesTabTests {
    static let inner = DailiesSheet.width - 40

    private func seed(_ probe: ViewProbe) {
        probe.controller.dailies.prepare(
            takes: [ControllerFixtures.take(named: "A001C01", in: probe.root)],
            settings: probe.controller.settings,
            defaultFolder: probe.root.appendingPathComponent("Dailies"))
    }

    @Test func theFilesTabFitsTheSheetInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            self.seed(probe)
            let model = probe.controller.dailies
            model.addSource(URL(fileURLWithPath: "/Volumes/CARD_A001/DCIM"))
            model.destinations.append(URL(fileURLWithPath: "/Volumes/SSD2/Dailies"))
            let minimum = probe.minimumWidths(proposedHeight: 300) {
                DailiesFilesTab(model: model)
            }
            #expect(minimum.en <= Self.inner,
                    "the files tab needs \(minimum.en)pt of \(Self.inner)")
            #expect(minimum.ru <= Self.inner,
                    "the files tab needs \(minimum.ru)pt of \(Self.inner)")
        }
    }

    /// **A day on eight cards does not grow the sheet.** The folder lists are
    /// the one part of this face with no bound, so each is a bounded scroll —
    /// the same rule the failure list follows.
    @Test func aLongCardListDoesNotGrowTheFace() async throws {
        try await ViewProbe.run { probe in
            self.seed(probe)
            let model = probe.controller.dailies
            let short = probe.sizes(proposedWidth: Self.inner) {
                DailiesFilesTab(model: model)
            }
            for index in 1...8 {
                model.addSource(URL(fileURLWithPath:
                    "/Volumes/CARD_A00\(index)/DCIM/100MEDIA"))
                model.destinations.append(URL(fileURLWithPath:
                    "/Volumes/SSD\(index)/Dailies"))
            }
            let long = probe.sizes(proposedWidth: Self.inner) {
                DailiesFilesTab(model: model)
            }
            #expect(long.en.height <= short.en.height + 60,
                    "eight cards added \(long.en.height - short.en.height)pt")
        }
    }
}

/// The queue the sheet will run: the app's own takes, or the folders.
@Suite @MainActor struct ModelDailiesSourceTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-src-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func noFoldersMeansTheDaysTakes() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C001", in: root)
            let model = controller.dailies
            model.prepare(takes: [take], settings: controller.settings,
                          defaultFolder: root)
            #expect(model.itemCount == 1)
            let items = model.plannedItems(settings: controller.settings)
            #expect(items.map(\.clipName) == ["A001C001"])
        }
    }

    /// **A folder replaces the takes rather than joining them.** Two sets of
    /// files under one Start is a batch nobody can predict the contents of.
    @Test func aFolderReplacesTheTakes() async throws {
        try await ControllerHarness.run { controller, root in
            let card = try self.scratch("card")
            defer { try? FileManager.default.removeItem(at: card) }
            for name in ["C0002.mov", "C0001.mov"] {
                try Data([0]).write(to: card.appendingPathComponent(name))
            }
            let take = ControllerFixtures.take(named: "A001C001", in: root)
            let model = controller.dailies
            model.prepare(takes: [take], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(card)
            #expect(await ControllerWait.until { !model.isScanning })

            #expect(model.itemCount == 2)
            let items = model.plannedItems(settings: controller.settings)
            // Name order, and the take is not in there.
            #expect(items.map(\.clipName) == ["C0001", "C0002"])
            #expect(items.allSatisfy { $0.startTimecode == nil },
                    "a camera clip was given a slate this app did not write")
            #expect(items.map(\.outputName)
                == ["C0001_DAILY", "C0002_DAILY"])
        }
    }

    /// …and taking the folder off the list puts the takes back.
    @Test func removingTheFolderPutsTheTakesBack() async throws {
        try await ControllerHarness.run { controller, root in
            let card = try self.scratch("card2")
            defer { try? FileManager.default.removeItem(at: card) }
            try Data([0]).write(to: card.appendingPathComponent("C0001.mov"))
            let take = ControllerFixtures.take(named: "A001C001", in: root)
            let model = controller.dailies
            model.prepare(takes: [take], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(card)
            #expect(await ControllerWait.until { !model.isScanning })
            #expect(model.itemCount == 1)
            model.removeSource(card)
            #expect(model.findings.files.isEmpty)
            #expect(model.plannedItems(settings: controller.settings)
                .map(\.clipName) == ["A001C001"])
        }
    }

    /// The same folder twice is one folder: an operator who clicks Add on a
    /// card that is already listed has not asked for its dailies twice.
    @Test func theSameFolderCannotBeAddedTwice() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(root)
            model.addSource(root)
            #expect(model.sources.count == 1)
        }
    }

    /// **The first destination cannot be taken off the list.** That is where
    /// the encode lands, and a run with nowhere to write is not a run — the
    /// extra shelves are copies of what it produces.
    @Test func theHeadDestinationCannotBeRemoved() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            let shelf = URL(fileURLWithPath: "/Volumes/SSD2/Dailies")
            model.addDestination(shelf)
            #expect(model.destinations.count == 2)

            model.removeDestination(model.destinations[0])
            #expect(model.destinations.count == 2,
                    "the encode's destination was removed")
            #expect(model.destination != nil)

            // …and an extra one goes.
            model.removeDestination(shelf)
            #expect(model.destinations.count == 1)
        }
    }

    /// The same shelf twice is one shelf — a second copy under a `_2` name is
    /// not what clicking Add on a listed folder asks for.
    @Test func theSameDestinationCannotBeAddedTwice() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            let shelf = URL(fileURLWithPath: "/Volumes/SSD2/Dailies")
            model.addDestination(shelf)
            model.addDestination(shelf)
            #expect(model.destinations.count == 2)
        }
    }

    /// Start refuses while a folder is still being walked: the queue is not
    /// known yet, and a run of "whatever the scan had reached" is a run the
    /// operator cannot check.
    @Test func startWaitsForTheScan() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.destinations = [root]
            model.addSource(root)
            // isScanning is set synchronously by `addSource`.
            #expect(model.isScanning)
            #expect(!model.canStart, "Start was live during the scan")
        }
    }
}

/// The folders come back with the next batch — the same card tree and the same
/// shuttle drive return every shooting day.
@Suite @MainActor struct ControllerDailiesFolderMemoryTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-mem-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func theFoldersSurviveTheRun() async throws {
        try await ControllerHarness.run { controller, root in
            let card = try self.scratch("card")
            let shelf = try self.scratch("shelf")
            defer {
                for url in [card, shelf] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(card)
            model.destinations.append(shelf)
            controller.rememberDailiesChoices(from: model)

            #expect(controller.settings.dailies.sourcePaths == [card.path])
            #expect(controller.settings.dailies.extraDestinationPaths
                == [shelf.path])

            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            // By PATH: a folder restored from settings carries a trailing
            // slash a picked one does not, which is the difference that used
            // to make Remove miss the row the operator clicked.
            #expect(model.sources.map(\.path) == [card.path])
            #expect(model.destinations.count == 2)
            #expect(model.destinations.last?.path == shelf.path)

            // …and Remove finds it despite that difference.
            model.removeSource(model.sources[0])
            #expect(model.sources.isEmpty, "Remove missed the restored folder")
        }
    }

    /// **A card that has been unplugged is not a source.** A list full of dead
    /// paths is a list nobody trusts, and a batch that silently rendered
    /// nothing because its only folder is gone is worse than one that says the
    /// list is empty.
    @Test func aFolderThatIsGoneDoesNotComeBack() async throws {
        try await ControllerHarness.run { controller, root in
            let card = try self.scratch("gone")
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            model.addSource(card)
            controller.rememberDailiesChoices(from: model)
            try FileManager.default.removeItem(at: card)

            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            #expect(model.sources.isEmpty,
                    "an unplugged card came back as a source: \(model.sources)")
        }
    }

    /// Nothing is stored at the default, like every other added field: a blob
    /// from a build without these keys still decodes, and one written here
    /// does not carry two empty arrays.
    @Test func nothingIsStoredWhenThereIsNothingToStore() async throws {
        try await ControllerHarness.run { controller, root in
            let model = controller.dailies
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: root)
            controller.rememberDailiesChoices(from: model)
            #expect(controller.settings.dailies.sourcePaths == nil)
            #expect(controller.settings.dailies.extraDestinationPaths == nil)
        }
    }
}
