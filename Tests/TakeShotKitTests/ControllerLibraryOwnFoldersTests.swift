import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Foreign content means content this app did not put there.**
///
/// Dailies land in `<record folder>/Dailies` by default and the scan walks the
/// record folder recursively, so every transcode the operator asked for came
/// back listed as somebody else's file (owner: "dailies добавляются как other
/// content"). An offload destination is the same rule with a sharper edge: a
/// card copied into the record folder is a hundred thousand files, and the
/// panel would list every one of them.
@Suite @MainActor struct ControllerLibraryOwnFoldersTests {
    /// A video that has SETTLED. The walk ignores anything written in the last
    /// three seconds — a file still being copied is not something to list — so
    /// a fixture written just now is invisible to it, which is a fine rule and
    /// a trap for a test.
    private func video(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: url.path)
    }

    /// The walk itself, given the folders to leave alone.
    @Test func theWalkSkipsTheFoldersThisAppWritesInto() async throws {
        try await ControllerHarness.run { _, root in
            let foreign = root.appendingPathComponent("SOMEONE_ELSE.mov")
            let daily = root.appendingPathComponent("Dailies/A001C001_h264.mov")
            let copied = root.appendingPathComponent("CardCopy/DCIM/A001C099.mov")
            try self.video(foreign)
            try self.video(daily)
            try self.video(copied)

            // resolved, as the walk compares them
            let skip = Set([root.appendingPathComponent("Dailies"),
                            root.appendingPathComponent("CardCopy")]
                .map { $0.resolvingSymlinksInPath().path })
            let found = CaptureController.findForeignVideos(
                root: root, excluding: [], skipping: skip)

            #expect(found.files.map(\.lastPathComponent) == ["SOMEONE_ELSE.mov"], """
                the walk listed our own output: \(found.files.map(\.lastPathComponent))
                """)
        }
    }

    /// …and without the list it finds all three, which is what makes the test
    /// above about the skipping rather than about the fixture.
    @Test func theSameWalkWithoutTheListFindsEverything() async throws {
        try await ControllerHarness.run { _, root in
            try self.video(root.appendingPathComponent("SOMEONE_ELSE.mov"))
            try self.video(root.appendingPathComponent("Dailies/A001C001_h264.mov"))
            try self.video(root.appendingPathComponent("CardCopy/DCIM/A001C099.mov"))

            let found = CaptureController.findForeignVideos(root: root, excluding: [])

            #expect(found.files.count == 3)
        }
    }

    /// **Two spellings of one folder are one folder.** `/var/folders/…` and
    /// `/private/var/folders/…` name the same place — `/var` is a symlink —
    /// and a comparison that mixes the two never matches, so nothing is ever
    /// skipped and the failure is silent.
    @Test func theSameFolderSpelledTwoWaysIsTheSameFolder() throws {
        // A folder that EXISTS, because that is the only case in which either
        // spelling can be folded onto the other — and it is the case that
        // happens: these are folders the app writes into.
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-spelling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }

        let privatePath = "/private" + real.standardizedFileURL.path
        try #require(FileManager.default.fileExists(atPath: privatePath),
                     "this machine does not spell the temp folder both ways")
        let ours: Set<String> = [URL(fileURLWithPath: privatePath)
            .standardizedFileURL.path]

        #expect(CaptureController.isOurs(real, folders: ours),
                "the two spellings did not compare equal")
    }

    /// **Anything UNDER one of our folders is ours too.** A directory
    /// enumerator is not required to hand back a directory before its
    /// contents, so a rule that only recognises the folder itself can miss
    /// everything inside it.
    @Test func anythingInsideOneOfOurFoldersIsOursAsWell() {
        let ours: Set<String> = ["/Volumes/SHUTTLE/CardCopy"]
        #expect(CaptureController.isOurs(
            URL(fileURLWithPath: "/Volumes/SHUTTLE/CardCopy/DCIM/A001.mov"),
            folders: ours), "a file inside our own folder was called foreign")
        // …and a sibling whose name merely starts the same way is NOT ours
        #expect(!CaptureController.isOurs(
            URL(fileURLWithPath: "/Volumes/SHUTTLE/CardCopyOther/A001.mov"),
            folders: ours), "a folder with a similar name was swallowed")
    }

    /// The controller names those folders from its own settings: the default
    /// dailies folder beside the footage, a dailies folder the operator chose
    /// instead, and every offload destination.
    @Test func theControllerNamesTheFoldersItWritesInto() async throws {
        try await ControllerHarness.run { controller, root in
            let chosen = root.appendingPathComponent("ElsewhereDailies")
            controller.settings.dailies.destinationPath = chosen.path
            controller.settings.offload.destinationPaths =
                [root.appendingPathComponent("Backup").path]

            let folders = controller.foldersThisAppWritesInto

            #expect(folders.contains(controller.defaultDailiesFolder
                .resolvingSymlinksInPath().path),
                    "the default dailies folder is not protected")
            #expect(folders.contains(chosen.resolvingSymlinksInPath().path),
                    "a chosen dailies folder is not protected")
            #expect(folders.contains(root.appendingPathComponent("Backup")
                .resolvingSymlinksInPath().path),
                    "an offload destination is not protected")
        }
    }
}
