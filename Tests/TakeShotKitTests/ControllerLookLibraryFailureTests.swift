import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The look library when the operator's hand slips, and the director's monitor
/// when the cable does.
///
/// A look that fails to import and says nothing is a colour decision made
/// behind the operator's back — the grade they think they are watching is not
/// the one on the glass. A display chosen and then unplugged is the same
/// problem one step further out.
@Suite @MainActor struct ControllerLookLibraryFailureTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-looks-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// The imported-look folder lives in Application Support, which is the
    /// operator's. Every test here points it at its own scratch directory
    /// first, and the Resolve mirror with it.
    private func withLookLibrary(
        _ body: (CaptureController, URL) async throws -> Void) async throws {
        let box = try scratch("library")
        defer { try? FileManager.default.removeItem(at: box) }
        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = box.appendingPathComponent("LUTs")
            controller.resolveLUTDirectory = box.appendingPathComponent("Resolve")
            try await body(controller, box)
        }
    }

    /// A minimal but real 2×2×2 .cube — the loader rejects anything that is
    /// merely named one, which is the point of the failing case below.
    private func writeCube(at url: URL) throws {
        let body = """
        TITLE "test"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - importing

    /// A look the app cannot copy has to say so. Silence here is the worst
    /// outcome available: the operator picked a grade, no error appeared, and
    /// the list simply does not have it.
    @Test func aLookThatCannotBeCopiedInSaysSo() async throws {
        try await withLookLibrary { controller, box in
            let missing = box.appendingPathComponent("never-written.cube")

            controller.adoptLooks(from: [missing])

            #expect(controller.lastError?
                .contains(localizedHead("toast_lut_import_failed")) == true,
                    "a failed look import went unannounced")
            #expect(controller.availableLUTs.isEmpty)
            #expect(controller.settings.lut.fileName == nil,
                    "a look that never arrived was selected anyway")
        }
    }

    /// …and one that can is copied in, listed, and becomes the selected look.
    /// The failing case above only means anything against this.
    @Test func aLookThatArrivesIsListedAndSelected() async throws {
        try await withLookLibrary { controller, box in
            let source = box.appendingPathComponent("Show_LUT.cube")
            try writeCube(at: source)

            controller.adoptLooks(from: [source])

            #expect(controller.availableLUTs.contains {
                $0.fileName == "Show_LUT.cube"
            })
            #expect(controller.settings.lut.fileName == "Show_LUT.cube")
            #expect(controller.lastError == nil)
        }
    }

    // MARK: - clearing

    /// "Clear imported LUTs" deletes the looks and nothing else. The folder is
    /// the app's own, but an operator who dropped something else in it should
    /// not lose it to a button about LUTs.
    @Test func clearingTheLibraryRemovesLooksAndLeavesTheRestAlone() async throws {
        try await withLookLibrary { controller, box in
            let source = box.appendingPathComponent("Show_LUT.cube")
            try writeCube(at: source)
            controller.adoptLooks(from: [source])
            try #require(controller.settings.lut.fileName == "Show_LUT.cube")
            let bystander = controller.lutsDirectory
                .appendingPathComponent("notes.txt")
            try Data("keep me".utf8).write(to: bystander)

            controller.clearLUTs()

            #expect(controller.availableLUTs.isEmpty)
            #expect(controller.settings.lut.fileName == nil,
                    "the selected look was deleted and stayed selected")
            #expect(!FileManager.default.fileExists(
                atPath: controller.lutsDirectory
                    .appendingPathComponent("Show_LUT.cube").path))
            #expect(FileManager.default.fileExists(atPath: bystander.path),
                    "clearing the looks took a file that was not one")
        }
    }

    /// The looks folder goes through the same helper every other "show it in
    /// the Finder" does, and reaches the folder the looks are actually in —
    /// which is not the record folder.
    @Test func theLooksFolderGoesThroughTheFinderHelper() async throws {
        let opened = Box()
        let previous = FinderOpen.handler
        FinderOpen.handler = { opened.urls.append($0) }
        defer { FinderOpen.handler = previous }

        try await withLookLibrary { controller, _ in
            controller.openLUTsInFinder()
            #expect(opened.urls == [controller.lutsDirectory])
        }
    }

    /// What the recorder collects. A reference type because the handler is a
    /// plain closure and the test reads it afterwards.
    private final class Box {
        var urls: [URL] = []
    }

    // MARK: - the director's monitor

    /// A display that is not attached gets no window. The picker keeps a stored
    /// display ID across launches and across a cart being packed down, so the
    /// common case is exactly this: the app comes back up and the monitor from
    /// yesterday is not there.
    @Test func aDisplayThatIsNotThereGetsNoWindow() async throws {
        try await ControllerHarness.run { controller, _ in
            try #require(controller.externalWindow == nil)

            // no CGDirectDisplayID is ever this: kCGNullDirectDisplay is 0 and
            // real IDs are assigned by the window server
            controller.externalDisplayID = CGDirectDisplayID.max

            #expect(controller.externalWindow == nil,
                    "a window was built for a display that is not attached")
            // NOT asserted against `availableScreens`: that property reads
            // `NSApp.mainWindow`, and `NSApp` is an implicitly unwrapped global
            // that is nil until an NSApplication exists. A test binary has
            // none, so touching it traps — see docs/coverage.md.

            // …and choosing "none" afterwards is not treated as a change to
            // rebuild for: the guard is what keeps a monitor somebody is
            // watching from flashing on every settings write
            controller.externalDisplayID = nil
            #expect(controller.externalWindow == nil)
        }
    }
}
