import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The three places the app touches something outside itself and has to cope
/// when the answer is nothing: a window the operator moved, a volume that
/// appeared, and a file the decoders cannot open.
///
/// Each is a seam's REAL side — the part a fake normally stands in for — kept
/// inside the test's own scratch directory. Nothing here mounts a disk, opens a
/// device, or puts a window on anybody's screen.
@Suite @MainActor struct ControllerHardwareSurfaceTests {
    /// What a decode attempt produced, as three Sendable facts.
    ///
    /// `nonisolated`, and it exists only to be: `OtherPreview` carries an
    /// `NSImage`, so handing the struct itself back to this main-actor suite
    /// sends a non-Sendable value across an isolation boundary. The macOS 26
    /// SDK does not complain and the macOS 15 one does — the same disagreement
    /// the `Sources` side is written around (docs/ARCHITECTURE.md). Reducing
    /// inside the nonisolated scope is right under either.
    private nonisolated static func previewFacts(
        for url: URL) async -> (hasImage: Bool, duration: Double?,
                                pixelSize: CGSize?) {
        let preview = await CaptureController.otherThumbnail(for: url)
        return (preview.image != nil, preview.duration, preview.pixelSize)
    }

    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-surface-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// Collected on the main actor, where the watch delivers.
    private final class Mounts {
        var mounted: [MountedVolume] = []
        var unmounted: [URL] = []
    }

    // MARK: - where the operator left the scopes window

    /// The frame travels with the app's own state rather than through AppKit's
    /// autosave, which writes to `UserDefaults.standard` under a name of its
    /// own — a suite may not touch that, and the injected suite cannot see it.
    /// So the thing to pin is that a move reaches the app's OWN defaults.
    @Test func movingTheScopesWindowStoresWhereItWasLeft() async throws {
        try await ControllerHarness.run { controller, _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)

            controller.keepScopesWindowFrame(window)
            #expect(controller.scopesFrame.window === window,
                    "the watch is not aimed at the window it was given")
            #expect(controller.defaults.string(
                forKey: CaptureController.scopesFrameKey) == nil,
                "nothing was moved yet, so nothing should have been written")

            window.setFrame(NSRect(x: 40, y: 60, width: 700, height: 500),
                            display: false)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification,
                                            object: window)

            #expect(await ControllerWait.until {
                controller.defaults.string(
                    forKey: CaptureController.scopesFrameKey) != nil
            }, "the window moved and nothing was stored")
            let text = try #require(controller.defaults.string(
                forKey: CaptureController.scopesFrameKey))
            // read back off the window rather than off the literal: AppKit is
            // free to adjust a frame, and what has to be stored is where the
            // window actually ended up
            #expect(NSRectFromString(text) == window.frame)
        }
    }

    /// Re-aiming replaces both halves at once. A watch still listening to the
    /// window before it would save the old window's frame over the operator's
    /// placement of the new one every time the old one moved.
    @Test func reaimingTheWatchLetsGoOfTheWindowBeforeIt() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            let second = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true)

            controller.keepScopesWindowFrame(first)
            controller.keepScopesWindowFrame(second)
            #expect(controller.scopesFrame.window === second)

            second.setFrame(NSRect(x: 10, y: 20, width: 720, height: 520),
                            display: false)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification,
                                            object: second)
            #expect(await ControllerWait.until {
                controller.defaults.string(
                    forKey: CaptureController.scopesFrameKey) != nil
            })

            // the window that is no longer watched must not overwrite it
            let afterSecond = try #require(controller.defaults.string(
                forKey: CaptureController.scopesFrameKey))
            first.setFrame(NSRect(x: 300, y: 300, width: 900, height: 700),
                           display: false)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification,
                                            object: first)
            _ = await ControllerWait.until({
                controller.defaults.string(
                    forKey: CaptureController.scopesFrameKey) != afterSecond
            }, timeout: .seconds(1))
            #expect(controller.defaults.string(
                forKey: CaptureController.scopesFrameKey) == afterSecond,
                "an abandoned window wrote over the watched one's frame")
        }
    }

    // MARK: - what a volume says about itself

    /// The recognition heuristic is handed answers rather than reaching for the
    /// filesystem itself, and this is where the answers come from. Asked about
    /// the test's own scratch directory it has to say what is true of it: a
    /// local disk nobody can walk away with, which is what stops the card offer
    /// appearing for the destination SSD.
    @Test func aScratchFolderIsDescribedAsTheFixedLocalDiskItSitsOn() throws {
        let dir = try scratch("describe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let described = WorkspaceVolumeWatch.describe(dir)

        #expect(described.url == dir)
        #expect(described.isLocal)
        #expect(!described.isDetachable,
                "the volume the suite runs on was taken for a card")
        #expect(!described.name.isEmpty)
    }

    /// A volume that answers nothing is assumed to be an ordinary local disk —
    /// defaulting to "not local" would switch the whole feature off on any
    /// filesystem that does not answer, rather than letting the heuristic decide.
    @Test func aVolumeThatAnswersNothingIsTakenForAnOrdinaryLocalDisk() {
        let ghost = URL(fileURLWithPath: "/Volumes/takeshot-no-such-volume-"
            + UUID().uuidString)

        let described = WorkspaceVolumeWatch.describe(ghost)

        #expect(described.name == ghost.lastPathComponent)
        #expect(described.uuid == nil)
        #expect(described.isLocal)
        #expect(described.isBrowsable)
        #expect(!described.isDetachable)
    }

    /// The watch itself, driven by the notification it exists to hear.
    ///
    /// The notification is posted into `NSWorkspace`'s centre by hand: nothing
    /// is mounted, no privilege is needed, and the only listener is the one this
    /// test installed and takes down again. Everything is matched on the
    /// scratch URL, so a disk somebody really plugs in while the suite runs
    /// cannot decide the result either way.
    @Test func theWorkspaceWatchDeliversWhatArrivedAndWhatLeft() async throws {
        let dir = try scratch("watch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Mounts()
        let watch = WorkspaceVolumeWatch()
        defer { watch.stop() }
        watch.onMount = { seen.mounted.append($0) }
        watch.onUnmount = { seen.unmounted.append($0) }
        watch.start()
        watch.start() // a second start must not install a second set

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: dir])
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: dir])
        // …and one carrying no URL at all, which must be ignored rather than
        // delivered as a mount of nothing
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [:])

        #expect(await ControllerWait.until {
            seen.mounted.contains { $0.url == dir }
                && seen.unmounted.contains(dir)
        }, "the watch heard nothing")
        #expect(seen.mounted.filter { $0.url == dir }.count == 1,
                "a second start installed a second set of observers")
        let described = try #require(seen.mounted.first { $0.url == dir })
        #expect(!described.isDetachable)

        watch.stop()
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: dir])
        _ = await ControllerWait.until({
            seen.mounted.filter { $0.url == dir }.count > 1
        }, timeout: .seconds(1))
        #expect(seen.mounted.filter { $0.url == dir }.count == 1,
                "the watch kept delivering after it was stopped")
    }

    // MARK: - a file the decoders cannot open

    /// Other content is whatever is in the record folder, and on a shooting day
    /// that includes files from cameras this build cannot decode. A failed
    /// decode has to come back as "no preview" — the panel still lists the file,
    /// and one bad card cannot take the whole scan down with it.
    @Test func aFileThatOnlyLooksLikeRawYieldsNoPreviewAndNoDuration() async throws {
        let dir = try scratch("foreign")
        defer { try? FileManager.default.removeItem(at: dir) }

        for ext in ["braw", "r3d"] {
            let url = dir.appendingPathComponent("A001_0001.\(ext)")
            try Data(repeating: 0x5A, count: 8192).write(to: url)

            let preview = await Self.previewFacts(for: url)

            #expect(!preview.hasImage, ".\(ext) decoded a picture out of noise")
            #expect(preview.duration == nil, ".\(ext) reported a length")
            #expect(preview.pixelSize == nil)
        }
    }

    /// The same for the still path: a `.png` that is not one. The decoders are
    /// asked, they say no, and the entry survives with no preview rather than
    /// the scan throwing.
    @Test func aStillThatIsNotDecodableYieldsNoPreview() async throws {
        let dir = try scratch("badstill")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("not-really.png")
        try Data(repeating: 0x11, count: 4096).write(to: url)

        let preview = await Self.previewFacts(for: url)

        #expect(!preview.hasImage)
        #expect(preview.pixelSize == nil)
        #expect(preview.duration == nil)
    }
}
