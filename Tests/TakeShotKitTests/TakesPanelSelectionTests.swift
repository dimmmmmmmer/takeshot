import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The takes panel as something an operator selects in: one click, cmd-click,
/// shift-click, and Delete meaning "move all of that to the Trash".
///
/// The two sections are one list to click through, so every range and every
/// action here is checked across the boundary between takes and Other content —
/// that seam is where a selection built from two separate lists goes wrong.
@Suite @MainActor struct TakesPanelSelectionTests {
    /// Two takes and two foreign files, all backed by real files so a rescan
    /// cannot retire them out from under the test.
    ///
    /// Discardable: the tests that walk `panelItemOrder` name the items through
    /// it rather than through what was seeded.
    @discardableResult
    private func seedPanel(_ controller: CaptureController,
                           in root: URL) throws -> (takes: [Take], other: [URL]) {
        let takes = (1...2).map {
            ControllerFixtures.take(
                named: "takeshot-test-A001C0\($0)", in: root, clip: $0,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
        }
        for take in takes { try ControllerFixtures.placeholder(for: take) }
        let other = ["takeshot-test-foreign1.mp4", "takeshot-test-foreign2.mp4"]
            .map { root.appendingPathComponent($0) }
        for url in other { try Data([0x00]).write(to: url) }
        controller.takes = takes
        controller.otherFiles = other
        return (takes, other)
    }

    /// The order the panel shows: takes newest first, then Other content. It is
    /// what a shift-range spans, so it is worth pinning on its own.
    @Test func thePanelOrderIsWhatThePanelShows() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)

            #expect(controller.panelItemOrder == [panel.takes[1].url,
                                                  panel.takes[0].url,
                                                  panel.other[0], panel.other[1]])
        }
    }

    @Test func aPlainClickSelectsExactlyOneItem() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)

            controller.clickPanelItem(panel.takes[0].url)
            #expect(controller.selectedItems == [panel.takes[0].url])

            // and replaces, rather than adding to, what was selected before
            controller.clickPanelItem(panel.other[1])
            #expect(controller.selectedItems == [panel.other[1]])
        }
    }

    @Test func commandClickTogglesOneItemAndLeavesTheRest() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)

            controller.clickPanelItem(panel.takes[0].url)
            controller.clickPanelItem(panel.other[0], command: true)
            #expect(controller.selectedItems == [panel.takes[0].url, panel.other[0]])

            controller.clickPanelItem(panel.takes[0].url, command: true)
            #expect(controller.selectedItems == [panel.other[0]],
                    "cmd-click on a selected item has to deselect it")
        }
    }

    /// A range from the anchor, across the section boundary — the takes and the
    /// foreign files are one list as far as clicking is concerned.
    @Test func shiftClickSelectsTheWholeRangeIncludingOtherContent() async throws {
        try await ControllerHarness.run { controller, root in
            try seedPanel(controller, in: root)
            let order = controller.panelItemOrder

            controller.clickPanelItem(order[0])
            controller.clickPanelItem(order[2], shift: true)
            #expect(controller.selectedItems == Set(order[0...2]))

            // a second shift-click measures from the SAME anchor and adds what it
            // spans, so clicking back towards the anchor leaves the run intact —
            // a moving anchor chained a new range on every click instead
            controller.clickPanelItem(order[1], shift: true)
            #expect(controller.selectedItems == Set(order[0...2]),
                    "the anchor moved: the earlier range was dropped")
        }
    }

    /// Shift-clicking before anything was clicked has no range to extend.
    @Test func shiftClickWithoutAnAnchorSelectsJustThatItem() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)

            controller.clickPanelItem(panel.other[1], shift: true)
            #expect(controller.selectedItems == [panel.other[1]])
        }
    }

    /// Delete moves everything selected out of the record folder. Where macOS
    /// files it afterwards is the Trash's business — what matters here is that
    /// nothing is left behind and nothing unselected was touched.
    @Test func trashingTheSelectionTakesEveryItemOutOfTheFolder() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)
            let doomed = [panel.takes[0].url, panel.other[0]]
            let kept = [panel.takes[1].url, panel.other[1]]

            controller.clickPanelItem(doomed[0])
            controller.clickPanelItem(doomed[1], command: true)
            let trashed = controller.trashSelection()

            #expect(trashed == 2)
            for url in doomed {
                #expect(!FileManager.default.fileExists(atPath: url.path),
                        "\(url.lastPathComponent) is still in the record folder")
            }
            for url in kept {
                #expect(FileManager.default.fileExists(atPath: url.path),
                        "\(url.lastPathComponent) was not selected and went anyway")
            }
            #expect(controller.takes.map(\.url) == [panel.takes[1].url])
            #expect(controller.otherFiles == [panel.other[1]])
            #expect(controller.selectedItems.isEmpty)
        }
    }

    /// The multi-delete is not a second implementation of deletion: a trashed
    /// take goes through `deleteTake`, so it leaves the metadata log exactly the
    /// way a single delete leaves it.
    @Test func trashingATakeRewritesTheLogThroughTheSinglePath() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)
            controller.setRating(.good, for: panel.takes[1])
            let csv = root.appendingPathComponent(TakeLogExporter.fileName)
            func text() -> String { (try? String(contentsOf: csv, encoding: .utf8)) ?? "" }
            _ = await ControllerWait.until {
                text().contains(panel.takes[0].url.lastPathComponent)
            }

            controller.clickPanelItem(panel.takes[0].url)
            controller.trashSelection()

            let rewritten = await ControllerWait.until {
                !text().contains(panel.takes[0].url.lastPathComponent)
            }
            #expect(rewritten, "the log was not rewritten after the trash")
            #expect(text().contains(panel.takes[1].url.lastPathComponent),
                    "the take that stayed lost its log entry")
        }
    }

    /// A file that cannot be moved keeps its place in the panel AND its place in
    /// the selection, so the operator can see what failed and try again.
    @Test func anItemThatCannotBeTrashedStaysSelected() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)
            let ghost = ControllerFixtures.take(named: "not-on-disk", in: root,
                                                clip: 9)
            controller.takes.append(ghost)

            controller.clickPanelItem(ghost.url)
            controller.clickPanelItem(panel.other[0], command: true)
            let trashed = controller.trashSelection()

            #expect(trashed == 1)
            #expect(controller.selectedItems == [ghost.url])
            #expect(controller.lastError?
                .hasPrefix(localizedHead("toast_delete_failed")) == true)
            #expect(controller.takes.contains { $0.url == ghost.url })
        }
    }

    /// Right-clicking an item that is part of the selection acts on the whole
    /// selection; right-clicking outside it acts on that one item — the rule
    /// Finder uses, and the one an operator's hands already know.
    @Test func aContextActionFollowsTheSelectionOnlyFromInsideIt() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)

            controller.clickPanelItem(panel.takes[0].url)
            controller.clickPanelItem(panel.other[0], command: true)

            #expect(controller.panelActionTargets(for: panel.takes[0].url).count == 2)
            #expect(controller.panelActionTargets(for: panel.other[1])
                        == [panel.other[1]])
        }
    }

    /// The number in the confirmation dialog and the number Delete actually
    /// moves have to be the same number, so both are read off the panel rather
    /// than off the raw set: for the moment between a file leaving the folder and
    /// the scan that prunes the selection, the set can still name it.
    @Test func theTrashCountIsWhatWillActuallyBeTrashed() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)
            controller.clickPanelItem(panel.takes[0].url)
            controller.clickPanelItem(panel.other[0], command: true)

            // the take has left the folder; the scan that would prune the
            // selection has not run yet
            controller.takes.removeAll { $0.url == panel.takes[0].url }

            #expect(controller.selectedItems.count == 2, "the set still names it")
            #expect(controller.selectedInOrder == [panel.other[0]],
                    "an item that is no longer in the panel was counted")
            #expect(controller.trashSelection() == 1,
                    "the dialog would have promised more than Delete moved")
        }
    }

    /// The DIT moving the day's footage to the archive is the normal way an item
    /// leaves the panel mid-shift. Delete must not then act on a stale URL.
    @Test func aSelectionDropsWhatLeftTheFolder() async throws {
        try await ControllerHarness.run { controller, root in
            let panel = try seedPanel(controller, in: root)
            // the anchor ends up on the take, so removing it exercises both the
            // selection and the anchor going stale at once
            controller.clickPanelItem(panel.other[0])
            controller.clickPanelItem(panel.takes[0].url, command: true)
            #expect(controller.selectionAnchor == panel.takes[0].url)

            controller.otherFiles.removeAll { $0 == panel.other[1] }
            controller.pruneSelection()
            #expect(controller.selectionAnchor == panel.takes[0].url,
                    "an unrelated file leaving must not move the anchor")

            controller.takes.removeAll { $0.url == panel.takes[0].url }
            controller.pruneSelection()

            #expect(controller.selectedItems == [panel.other[0]])
            #expect(controller.selectionAnchor == nil,
                    "the anchor pointed at an item that is gone")
        }
    }

    /// The count in the confirmation dialog is a translated string, and Russian
    /// needs three plural forms for it. A `.stringsdict` would pick the form from
    /// the system locale, which is the wrong language when the UI is switched by
    /// hand — hence the arithmetic, and hence this.
    @Test func theItemCountAgreesWithTheNumberInBothLanguages() {
        ViewRender.withLanguage(.english) {
            #expect(localizedItemCount(1) == "1 item")
            #expect(localizedItemCount(3) == "3 items")
            #expect(localizedItemCount(11) == "11 items")
        }
        ViewRender.withLanguage(.russian) {
            #expect(localizedItemCount(1) == "1 объект")
            #expect(localizedItemCount(2) == "2 объекта")
            #expect(localizedItemCount(5) == "5 объектов")
            #expect(localizedItemCount(11) == "11 объектов",
                    "11 takes the many form, not the one form")
            #expect(localizedItemCount(21) == "21 объект")
            #expect(localizedItemCount(22) == "22 объекта")
            #expect(localizedItemCount(112) == "112 объектов")
        }
    }

    /// The strings the count is dropped into. These take `%@`, not `%d`, and a
    /// mismatch between the format and the argument does not fail to compile —
    /// it renders a pointer, or nothing, in a destructive confirmation dialog.
    @Test func theTrashStringsCompose() {
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                let three = localizedItemCount(3)
                for key in ["trash_confirm", "trash_done", "trash_selection",
                            "reveal_selection"] {
                    let composed = L(key, three)
                    #expect(composed.contains(three),
                            "\(key) in \(language.rawValue) lost the count: \(composed)")
                    #expect(composed != key, "\(key) is not in the .strings file")
                    #expect(!composed.contains("%"),
                            "\(key) in \(language.rawValue) has a leftover format: \(composed)")
                }
            }
        }
    }
}
