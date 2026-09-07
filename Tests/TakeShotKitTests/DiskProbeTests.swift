import Foundation
import Testing

@testable import TakeShotKit

/// **The record volume is asked off the main actor, and that is the whole
/// point.**
///
/// A `statfs` against a healthy SSD is microseconds; against an SMB share that
/// has gone to sleep it is the SMB client's timeout, with no error until it
/// expires. The disk watchdog asked one every two seconds while a take rolled,
/// the remote status page another every five, and the folder scan a stat per
/// take once a minute — all on the actor that draws the REC button.
///
/// So the failure was the exact inverse of the feature: a watchdog that exists
/// to stop a take before the card fills, freezing the app — including the
/// operator's ability to press stop — at the moment the volume became slow,
/// which is the moment before it becomes unavailable.
struct DiskProbeTests {
    @Test @MainActor
    func aReadingIsTakenOnTheOneSerialQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-diskprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reading = await DiskProbe.read(root: root, openTake: nil)
        // The QUEUE and not merely "not the main thread": a nonisolated async
        // function is already off main, so the weaker assertion passes against
        // a version with no queue at all — one probe per tick, piling up
        // behind a share that has stopped answering, each holding a thread.
        #expect(reading.queue == DiskProbe.queueLabel,
                "the volume was asked on \(reading.queue)")
        #expect(reading.freeBytes != nil,
                "a mounted volume would not say how much room it has")
    }

    /// A destination that is not there is recreated by the probe, and the
    /// answer says so — which is what keeps the watchdog from alarming over a
    /// folder somebody just renamed.
    @Test func anAbsentFolderIsRecreatedAndReported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-diskprobe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let reading = await DiskProbe.read(root: root, openTake: nil)
        #expect(reading.folderExists,
                "the probe neither found nor made the destination folder")
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// The open take's size comes back with the free space, on the same hop.
    ///
    /// It used to be a second `stat` from `measuredWriteRate`, on the main
    /// actor, immediately after the `statfs` — so a sleeping share cost two
    /// timeouts per tick rather than one, and both of them on the actor.
    @Test func theOpenTakeSizeComesBackWithTheFreeSpace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-diskprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "A001_C001.mov"
        try Data(repeating: 7, count: 4_096)
            .write(to: root.appendingPathComponent(name))

        let reading = await DiskProbe.read(root: root, openTake: name)
        #expect(reading.takeBytes == 4_096,
                "the open take measured \(reading.takeBytes ?? -1) bytes")
        // …and nothing is measured when nothing is open, so a stat is not paid
        // for on every idle tick.
        let idle = await DiskProbe.read(root: root, openTake: nil)
        #expect(idle.takeBytes == nil)
    }

    /// The batched existence sweep: one hop for the whole take list.
    @Test func theExistenceSweepAnswersForEveryPathAtOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-diskprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let here = root.appendingPathComponent("here.mov")
        try Data([1]).write(to: here)
        let gone = root.appendingPathComponent("gone.mov").path

        let present = await DiskProbe.present([here.path, gone])
        #expect(present == [here.path],
                "the sweep answered \(present)")
    }
}
