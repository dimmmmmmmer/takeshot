import CaptureCore
import Foundation

/// One look at the record volume, taken OFF the main actor.
///
/// **Every call in here can park for as long as the filesystem wants.** A
/// `statfs` against a healthy SSD is microseconds and against an SMB share that
/// has gone to sleep it is the SMB client's timeout — tens of seconds, with no
/// error until it expires. The disk watchdog runs one of these every two
/// seconds while a take rolls, `sampleRemoteDisk` another every five, and the
/// folder scan a stat per take once a minute; all of them used to run ON the
/// main actor, which is where the REC button lives.
///
/// So the failure was the exact inverse of the feature: the watchdog exists to
/// stop a take before the card fills, and the way it failed was to freeze the
/// app — including the operator's ability to press stop — at the moment the
/// volume became slow, which is the moment before it becomes unavailable.
///
/// Nothing here touches the controller and nothing here decides anything: it
/// reads, and the verdict is taken on the main actor from the values it brings
/// back (`CaptureController.applyDiskReading`).
enum DiskProbe {
    /// What one look found. Every field is nil-able because "the volume did not
    /// answer" is a real answer and the one the watchdog exists for.
    struct Reading: Sendable {
        /// Free bytes for important usage, or nil when the volume would not say.
        var freeBytes: Int64?
        /// The open take's size on disk, for the growth pair the write-rate is
        /// measured from. nil when nothing is open or the file would not answer.
        var takeBytes: Int64?
        /// Whether the destination folder is there — asked only when the free
        /// space could not be read, and asked AFTER trying to recreate it, so
        /// `true` covers both "it was there all along" and "this probe made it".
        var folderExists = false
        /// The label of the queue this reading was taken on.
        ///
        /// A field on the value rather than a comment, because WHERE the
        /// reading happened is the entire point of this type and is invisible
        /// from outside otherwise. `DiskProbeTests` requires it to be
        /// `DiskProbe.queueLabel`, which pins both halves at once: off the
        /// main actor, and on the one SERIAL queue — a nonisolated `async`
        /// function is already off main, so "not the main thread" would have
        /// passed against a version with no queue at all and a probe per tick
        /// piling up behind a share that stopped answering.
        var queue = ""
    }

    /// A serial queue, so two probes cannot overlap and a slow one cannot pile
    /// up behind itself. `utility` rather than `background`: the answer gates a
    /// recording alarm, so it must not be parked behind Time Machine.
    static let queueLabel = "takeshot.disk"
    private static let queue = DispatchQueue(label: queueLabel, qos: .utility)

    /// Where the calling code is running, by label. `dispatch_queue_get_label`
    /// with a nil queue answers for the CURRENT one, which is the only way to
    /// ask this question at all.
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    static func read(root: URL, openTake: String?) async -> Reading {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: probe(root: root,
                                                     openTake: openTake))
            }
        }
    }

    private static func probe(root: URL, openTake: String?) -> Reading {
        var reading = Reading()
        reading.queue = currentQueueLabel()
        // `VolumeSpace` owns which of the volume's two answers to believe:
        // this used to ask for the boot-volume key alone, so a record folder
        // on an external drive that answers 0 for it would have raised the
        // disk alarm over a disk with terabytes free.
        reading.freeBytes = VolumeSpace.free(of: root)
        if reading.freeBytes == nil {
            // Asking a volume that is no longer mounted is exactly how the
            // query above fails. A merely absent FOLDER is recoverable and
            // normal (a fresh destination path), so try that first — and the
            // recreate is I/O too, which is why it happens here and not on the
            // actor that has to draw the alarm.
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            reading.folderExists =
                FileManager.default.fileExists(atPath: root.path)
        }
        if let openTake {
            let url = root.appendingPathComponent(openTake)
            reading.takeBytes = (try? FileManager.default.attributesOfItem(
                atPath: url.path))?[.size] as? Int64
        }
        return reading
    }

    /// Which of `paths` are still on disk. One stat each, and the reason they
    /// are batched here is arithmetic: a day of two hundred takes is two
    /// hundred stats, and on a share whose timeout is a second that is three
    /// minutes of a frozen main actor once a minute.
    static func present(_ paths: Set<String>) async -> Set<String> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: paths.filter {
                    FileManager.default.fileExists(atPath: $0)
                })
            }
        }
    }
}
