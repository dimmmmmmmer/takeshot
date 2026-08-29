import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The picker both the compare bar and the chroma plate use (owner item 36).
///
/// The complaint was two-sided: the plate could only be found through a file
/// panel, and the compare's B side listed the day's takes in one flat run with
/// no way to reach the reference clips sitting in the same folder. One list is
/// the answer to the first and the reason the second is unreadable — so the
/// list is grouped, and both places use the same one.
@MainActor
struct ModelMediaSourceTests {
    /// Two takes and two Other files, one of each Other kind.
    private func seed(_ probe: ViewProbe) throws -> (takes: [Take], other: [URL]) {
        let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
        let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                    in: probe.root)
        return (takes, other)
    }

    /// Takes and Other content come back as two groups, in that order, never
    /// merged — and each group names itself in both languages.
    @Test func theSourcesComeBackAsTwoNamedGroups() async throws {
        try await ViewProbe.run { probe in
            let seeded = try seed(probe)
            let groups = probe.controller.mediaSources(.any)

            #expect(groups.map(\.group) == [.takes, .other],
                    "the two groups are merged or out of order")
            #expect(groups[0].items.map(\.url) == seeded.takes.map(\.url))
            #expect(groups[1].items.map(\.url) == seeded.other)
            // a take is named the way the takes panel names it, an Other file
            // by its file name
            #expect(groups[0].items.first?.name == "TS_A001C01")
            #expect(groups[1].items.map(\.name)
                    == ["A003_C012_0714XY.mov", "reference.png"])

            for language in [AppLanguage.english, .russian] {
                let labels = ViewRender.withLanguage(language) {
                    MediaSourceGroup.allCases.map { L($0.labelKey) }
                }
                #expect(Set(labels).count == 2,
                        "\(language) calls both groups the same: \(labels)")
                #expect(labels.allSatisfy { !$0.hasPrefix("media_group_") },
                        "\(language) is missing a group heading: \(labels)")
            }
        }
    }

    /// The compare's B side needs a transport, so it takes clips only: the
    /// still in Other content is not offered there and IS offered as a plate.
    @Test func theVideoOnlyFilterDropsTheStills() async throws {
        try await ViewProbe.run { probe in
            _ = try seed(probe)
            let video = probe.controller.mediaSources(.video)
            let everything = probe.controller.mediaSources(.any)

            let videoNames = video.flatMap { $0.items.map(\.name) }
            #expect(!videoNames.contains("reference.png"),
                    "a still was offered as a compare clip: \(videoNames)")
            #expect(videoNames.contains("A003_C012_0714XY.mov"))
            #expect(everything.flatMap { $0.items }.count
                    == video.flatMap { $0.items }.count + 1)
        }
    }

    /// An empty group is dropped rather than shown as a heading with nothing
    /// under it, and with nothing at all the picker has no groups.
    @Test func emptyGroupsAreNotOffered() async throws {
        try await ViewProbe.run { probe in
            #expect(probe.controller.mediaSources(.any).isEmpty)

            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            #expect(probe.controller.mediaSources(.any).map(\.group) == [.takes])

            probe.controller.takes = []
            try ViewFixtures.seedOtherFiles(probe.controller, in: probe.root)
            #expect(probe.controller.mediaSources(.any).map(\.group) == [.other])
        }
    }

    /// The chosen file names itself whichever group it came from — the compare
    /// menu's own label used to look its selection up in the takes alone, so an
    /// Other clip would have shown as a bare "B".
    @Test func aChosenFileNamesItselfFromEitherGroup() async throws {
        try await ViewProbe.run { probe in
            let seeded = try seed(probe)
            #expect(probe.controller.mediaSourceName(for: seeded.takes[0].url)
                    == "TS_A001C01")
            #expect(probe.controller.mediaSourceName(for: seeded.other[0])
                    == "A003_C012_0714XY.mov")
            #expect(probe.controller.mediaSourceName(
                for: probe.root.appendingPathComponent("gone.mov")) == nil)
        }
    }

    /// What identifies a row, which is what SwiftUI's `ForEach` reuses views
    /// by. A picker row is its URL and not its NAME: a reference plate copied
    /// into two folders under one name is two files, and identifying them by
    /// name would collapse them into one row that opens whichever the diff
    /// happened to keep. The two group ids are the same claim one level up —
    /// the heading a group keeps across a rebuild is its kind, not its
    /// position in the array, because `mediaSources` drops empty groups and
    /// the array's indices therefore move.
    @Test func aPickerRowIsIdentifiedByItsFileAndNotItsName() {
        let folderA = URL(fileURLWithPath: "/tmp/a/plate.png")
        let folderB = URL(fileURLWithPath: "/tmp/b/plate.png")
        let rowA = MediaSourceItem(url: folderA, name: "plate.png")
        let rowB = MediaSourceItem(url: folderB, name: "plate.png")
        #expect(rowA.id == folderA)
        #expect(rowA.id != rowB.id, "two files of one name collapse to one row")
        #expect(rowA.name == rowB.name, "the names really are the same")

        for group in MediaSourceGroup.allCases {
            #expect(group.id == group.rawValue)
            #expect(MediaSourceGroupItems(group: group, items: [rowA]).id
                    == group.rawValue)
        }
        #expect(Set(MediaSourceGroup.allCases.map(\.id)).count
                == MediaSourceGroup.allCases.count)
    }

    /// Both places really do use it, and the plate takes stills as well as
    /// clips — the compare bar's B menu and the plate row are measured with a
    /// seeded folder so a picker that lists nothing cannot pass.
    @Test func bothPickersOfferTheGroupedSources() async throws {
        try await ViewProbe.run { probe in
            _ = try seed(probe)
            let controller = probe.controller

            // both really are built from the shared rows, structurally — a
            // second hand-rolled list in either place fails here
            #expect(String(describing: CompareControls.Body.self)
                .contains("MediaSourceMenuItems"),
                    "the compare bar went back to a list of its own")
            #expect(String(describing: ChromaPlateControls.Body.self)
                .contains("MediaSourceMenuItems"),
                    "the plate went back to a file panel and nothing else")

            // the plate offers everything, the compare only what has a
            // transport — and both go through the same call
            #expect(controller.chromaPlateSources.map(\.group) == [.takes, .other])
            #expect(controller.chromaPlateSources.flatMap { $0.items.map(\.name) }
                .contains("reference.png"))
            #expect(controller.mediaSources(.video).map(\.group)
                    == [.takes, .other])

            // and the rows render, in both languages, without stretching past
            // the popover the plate section lives in
            controller.chromaKeyOn = true
            controller.chromaBackground = .image
            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { ChromaPlateControls() }
            #expect(minimum.ru <= box,
                    "the Russian plate rows want \(minimum.ru)pt of \(box)")
            #expect(minimum.en <= box)

            // the B menu is on screen with a compare engaged, and the bar it
            // sits in still squeezes into the player's own chrome width (the
            // centered slot is the other agent's item, not this one)
            controller.viewerMode = .playback
            controller.playbackURL = probe.root.appendingPathComponent("x.mov")
            controller.compareMode = .wipe
            let compare = probe.minimumWidths { CompareControls() }
            #expect(compare.ru <= ViewBudget.playerChromeWidth,
                    "the compare bar with the B menu wants \(compare.ru)pt")
            #expect(compare.en <= ViewBudget.playerChromeWidth)
        }
    }
}
