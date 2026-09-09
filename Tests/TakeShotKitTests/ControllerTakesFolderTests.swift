import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Takes go into `Takes/` in a folder that was empty when the shoot
/// started**, and nowhere different in a folder that was not (owner: "чтоб у
/// нас короче было сразу по дефолту разделение папки на другой контент и
/// тейки", with the new-folders-only variant chosen deliberately).
@Suite @MainActor struct ControllerTakesFolderTests {
    @Test func aFreshRecordFolderPutsTakesInTheirOwnSubfolder() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(controller.takesFolder.path
                == root.appendingPathComponent("Takes").path)
        }
    }

    /// A folder with a day already in it is left exactly as it is — the whole
    /// of the migration story: nothing moves and nothing is reclassified.
    @Test func anEstablishedFolderKeepsWritingWhereItAlwaysDid() async throws {
        try await ControllerHarness.run { controller, root in
            try Data([0]).write(
                to: root.appendingPathComponent("takeshot-log.csv"))
            #expect(controller.takesFolder.path == root.path)
        }
    }

    /// The name-taken warning asks about the folder the take will actually be
    /// written into. It used to ask the record folder, which in the split
    /// layout is where the take is NOT — so a name already in use would have
    /// gone unreported.
    @Test func theNameTakenWarningLooksWhereTheTakeWillLand() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = root.appendingPathComponent("Takes")
            try FileManager.default.createDirectory(
                at: takes, withIntermediateDirectories: true)
            let name = controller.pendingTakeName
            try Data([0]).write(to: takes.appendingPathComponent("\(name).mov"))

            controller.refreshNameCollision()
            #expect(controller.nameCollision == "\(name).mov",
                    "the warning looked in the wrong folder")
        }
    }

    /// …and it does not fire for a file of that name sitting in the ROOT,
    /// which in the split layout is somebody else's content.
    @Test func aFileInTheRootIsNotANameCollision() async throws {
        try await ControllerHarness.run { controller, root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Takes"),
                withIntermediateDirectories: true)
            let name = controller.pendingTakeName
            try Data([0]).write(to: root.appendingPathComponent("\(name).mov"))

            controller.refreshNameCollision()
            #expect(controller.nameCollision == nil,
                    "the root's other content was read as a take's name")
        }
    }

    /// The two panels' folder buttons are two different answers now, and the
    /// one for Other content is the record folder itself.
    @Test func theTwoPanelsPointAtTwoFolders() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(controller.takesFolder != controller.destinationRoot)
            #expect(controller.destinationRoot == root)
        }
    }
}
