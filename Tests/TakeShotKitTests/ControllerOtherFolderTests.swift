import Foundation
import Testing

@testable import TakeShotKit

/// **Where an Other-content file actually is.**
///
/// The scan walks the whole record folder, subfolders included, and the list
/// showed nothing but a file name (owner: "other content в принципе не
/// учитывает папки"). Two rows reading `A001C001.mov` were routinely two
/// different files in two folders, with nothing on screen to tell them apart —
/// and Play, Reveal and Delete each aimed at whichever one the row held.
@MainActor @Suite struct ControllerOtherFolderTests {
    @Test func aFileInTheRecordFolderIsLabelledWithNothing() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root.appendingPathComponent("A001C001.mov")
            #expect(controller.otherFolderText(for: url) == nil)
        }
    }

    @Test func aFileInASubfolderIsLabelledWithIt() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root.appendingPathComponent("Dailies/A001C001.mov")
            #expect(controller.otherFolderText(for: url) == "Dailies")
        }
    }

    /// Nested folders read as a path, not just the last one: "DCIM" alone is
    /// the same label under two cards, which is the collision this exists to
    /// remove rather than reproduce one level down.
    @Test func aNestedFileIsLabelledWithThePathBelowTheRoot() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root
                .appendingPathComponent("CARD_A/DCIM/100CANON/A001C001.mov")
            #expect(controller.otherFolderText(for: url)
                == "CARD_A/DCIM/100CANON")
        }
    }

    /// A folder name that starts the way the root's does is not the root: a
    /// prefix test without the separator would cut "…/RecordsOld/x.mov" at the
    /// wrong place and label it "ld".
    @Test func aSiblingFolderWithASharedPrefixIsNotTreatedAsInside() async throws {
        try await ControllerHarness.run { controller, root in
            let sibling = root.deletingLastPathComponent()
                .appendingPathComponent(root.lastPathComponent + "Old")
            let url = sibling.appendingPathComponent("A001C001.mov")
            let label = try #require(controller.otherFolderText(for: url))
            #expect(label == sibling.path,
                    "a sibling folder was read as being inside the root")
        }
    }

    /// The root itself may be spelled with a trailing slash or with `.`
    /// segments; a file directly in it is still directly in it.
    @Test func theRootIsRecognisedThroughAnUntidyPath() async throws {
        try await ControllerHarness.run { controller, root in
            let url = root.appendingPathComponent("./A001C001.mov")
            #expect(controller.otherFolderText(for: url) == nil)
        }
    }
}
