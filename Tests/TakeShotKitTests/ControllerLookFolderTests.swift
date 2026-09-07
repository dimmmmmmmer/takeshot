import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Where the look library lives, when it is not where the app put it.
///
/// A unit keeps the show's LUTs on the show drive, beside the record folder,
/// and until now the only library the app would read was its own folder in
/// Application Support (owner: "path папки лутов хочу чтобы можно было
/// выбирать"). Re-pointing it is not just a path assignment: the list, the
/// cached cube and the selected look all hang off the folder, and each one of
/// them left behind is a way for the operator to be shown a grade that is not
/// the one they picked.
@Suite @MainActor struct ControllerLookFolderTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-lutfolder-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// A real 2×2×2 .cube whose white end is `white` — two libraries can then
    /// hold a `show.cube` each and the loader can tell them apart, which is the
    /// whole point of the cache test below.
    private func writeCube(at url: URL, white: Double) throws {
        let body = """
        TITLE "show"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        \(white) \(white) \(white)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A controller whose library is its own scratch folder, plus a second
    /// folder to move it to. The Resolve mirror is pointed at scratch too: an
    /// import in here must not land in the operator's real Resolve LUT folder.
    private func withTwoLibraries(
        _ body: (CaptureController, URL, URL) async throws -> Void) async throws {
        let box = try scratch("box")
        defer { try? FileManager.default.removeItem(at: box) }
        let first = box.appendingPathComponent("first")
        let second = box.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        }
        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = first
            controller.resolveLUTDirectory = box.appendingPathComponent("Resolve")
            controller.reloadLUTList()
            try await body(controller, first, second)
        }
    }

    // MARK: - choosing one

    /// The panel's answer becomes the library, is read back from it, and is
    /// what the next launch will be told.
    @Test func aChosenFolderBecomesTheLibraryAndIsRemembered() async throws {
        try await withTwoLibraries { controller, _, second in
            try writeCube(at: second.appendingPathComponent("show.cube"), white: 1)

            try await FakeFilePanel.installed(opening: [[second]]) { panel in
                controller.chooseLUTsFolder()

                // a folder picker, not a file one: a library is a directory,
                // and a panel that also took files would let the operator
                // answer this question with a .mov
                #expect(panel.openRequests.last?.directories == true)
                #expect(panel.openRequests.last?.files == false)
            }

            #expect(controller.lutsDirectory.path == second.path)
            #expect(controller.settings.lut.folderPath == second.path,
                    "the chosen library will not survive a relaunch")
            #expect(controller.availableLUTs.map(\.fileName) == ["show.cube"],
                    "the list still shows the folder the operator left")
        }
    }

    /// Cancel leaves the library where it was. Nothing here is destructive, but
    /// a picker that re-points the library when the operator backs out of it is
    /// how a show's looks disappear from the menu mid-setup.
    @Test func cancellingThePickerLeavesTheLibraryWhereItWas() async throws {
        try await withTwoLibraries { controller, first, _ in
            try await FakeFilePanel.installed(opening: [[]]) { _ in
                controller.chooseLUTsFolder()
            }

            #expect(controller.lutsDirectory.path == first.path)
            #expect(controller.settings.lut.folderPath == nil)
        }
    }

    /// "Default" puts it back where imports land, and forgets the path — the
    /// operator has to be able to get home from a drive that is no longer on
    /// the truck.
    @Test func theDefaultPutsTheLibraryBackAndForgetsThePath() async throws {
        try await withTwoLibraries { controller, _, second in
            controller.setLUTsFolder(second)
            #expect(controller.settings.lut.folderPath != nil)

            controller.setLUTsFolder(nil)

            #expect(controller.settings.lut.folderPath == nil)
            #expect(controller.lutsDirectory == CaptureController.defaultLUTsDirectory)
        }
    }

    // MARK: - what hangs off the folder

    /// **The cached cube is keyed by FILE NAME alone.** Two libraries each
    /// holding their own `show.cube` is the ordinary case — every show names
    /// its show LUT after the show — and a cache that survives the move shows
    /// the operator the first library's grade under the second library's name.
    @Test func theSecondLibrarysOwnGradeIsNotTheFirstsUnderTheSameName() async throws {
        try await withTwoLibraries { controller, first, second in
            try writeCube(at: first.appendingPathComponent("show.cube"), white: 1)
            try writeCube(at: second.appendingPathComponent("show.cube"), white: 0.5)
            controller.reloadLUTList()
            controller.selectLUT(fileName: "show.cube")
            let firstGrade = try #require(controller.currentCube?.data)

            controller.setLUTsFolder(second)

            let shown = try #require(controller.currentCube?.data,
                                     "the selected look was dropped, not reloaded")
            let onDisk = try CaptureController
                .readLook(at: second.appendingPathComponent("show.cube")).0.data
            #expect(shown == onDisk,
                    "the second library's show.cube is not what is being applied")
            #expect(shown != firstGrade,
                    "the first library's grade survived the move")
        }
    }

    /// A selection the new library does not hold is simply gone — quietly. It
    /// reaching the operator as a load failure would be the app reporting an
    /// error for something they did on purpose.
    @Test func aSelectionTheNewLibraryDoesNotHaveIsDroppedWithoutAnError() async throws {
        try await withTwoLibraries { controller, first, second in
            try writeCube(at: first.appendingPathComponent("show.cube"), white: 1)
            controller.reloadLUTList()
            controller.selectLUT(fileName: "show.cube")
            controller.lastError = nil

            controller.setLUTsFolder(second)

            #expect(controller.settings.lut.fileName == nil)
            #expect(controller.currentCube == nil)
            #expect(controller.lastError == nil,
                    "changing library reported a look failure the operator did not cause")
        }
    }

    // MARK: - the next launch

    /// The stored path IS the library at launch, and it is read before the list
    /// is: a folder adopted after the scan would leave the operator looking at
    /// the app's own folder until something else happened to rescan.
    @Test func aStoredLibraryIsTheOneScannedAtLaunch() async throws {
        let library = try scratch("stored")
        defer { try? FileManager.default.removeItem(at: library) }
        try writeCube(at: library.appendingPathComponent("show.cube"), white: 1)

        try await ControllerHarness.run(configure: {
            $0.lut.folderPath = library.path
        }, { controller, _ in
            #expect(controller.lutsDirectory.path == library.path)
            #expect(controller.availableLUTs.map(\.fileName) == ["show.cube"],
                    "the stored library was adopted after the scan, not before it")
        })
    }

    /// No stored path leaves the library alone. The suites inject
    /// `lutsDirectory` so their fixtures never land in the operator's real
    /// Application Support folder; a startup that assigned unconditionally
    /// would undo that injection for every one of them.
    @Test func noStoredPathLeavesTheInjectedLibraryAlone() async throws {
        try await withTwoLibraries { controller, first, _ in
            controller.adoptStoredLUTFolder(controller.settings)

            #expect(controller.lutsDirectory.path == first.path)
        }
    }
}
