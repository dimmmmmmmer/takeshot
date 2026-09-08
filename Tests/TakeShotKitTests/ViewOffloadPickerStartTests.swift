import Foundation
import Testing

@testable import TakeShotKit

/// **Where the folder panel opens when there is already a choice.**
///
/// At the root of the disk that choice is on — not inside the folder being
/// replaced. Choosing again is almost always "same drive, different folder":
/// the drive is what the operator plugged in, the folder is what they are
/// changing, and a panel that opens inside the current folder makes them climb
/// out of it first (owner: "сделай так чтоб у источника или результирующего
/// источника finder изначально открывал его корень. типа диск я выбрал но
/// папку может поменять зочу").
@Suite @MainActor struct ViewOffloadPickerStartTests {
    /// A path that EXISTS answers with its volume's root. Asserted against the
    /// machine's own answer rather than a fabricated one: the key being read
    /// (`volumeURLKey`) is answered by the file system, so a made-up path would
    /// only prove the climb.
    @Test func aPathAnswersWithTheRootOfItsVolume() throws {
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-volumeroot-\(UUID().uuidString)")
            .appendingPathComponent("DCIM/100MEDIA")
        try FileManager.default.createDirectory(at: deep,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: deep.deletingLastPathComponent().deletingLastPathComponent())
        }
        let root = try #require(OffloadPanels.volumeRoot(of: deep))

        let expected = try #require(
            try deep.resourceValues(forKeys: [.volumeURLKey]).volume)
        #expect(root == expected, "answered \(root), volume is \(expected)")
        // …and it is a ROOT: nothing of the path survives in it
        #expect(!root.path.contains("100MEDIA"))
    }

    /// Nothing chosen yet is nothing to be near: the panel opens where it was
    /// last, which is the system's own memory and better than any guess here.
    @Test func noChoiceIsNoStartingPoint() {
        #expect(OffloadPanels.volumeRoot(of: nil) == nil)
    }

    /// **A drive that is not mounted lands on `/Volumes`** — where an operator
    /// goes looking for it — rather than on a path that is not there.
    ///
    /// This is the case the climb exists for, and it is not rare: the paths
    /// this function is handed are a destination folder that may not have been
    /// created yet and a shuttle that may have been unplugged since.
    @Test func anUnmountedDriveLandsWhereItWouldBeLookedFor() throws {
        let missing = URL(fileURLWithPath: "/Volumes/NOT_MOUNTED_XYZ/yep/CacheClip")
        let root = try #require(OffloadPanels.volumeRoot(of: missing))
        #expect(!root.path.contains("CacheClip"),
                "the panel would open inside the folder being replaced")
        #expect(!root.path.contains("NOT_MOUNTED_XYZ"),
                "the panel would open on a drive that is not there")
    }
}
