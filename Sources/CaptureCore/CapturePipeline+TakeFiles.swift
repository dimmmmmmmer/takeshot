import Foundation

/// Where a take's file goes: the path the naming template builds, the
/// process-wide reservation that keeps two pipelines off the same name, and the
/// rename that marks a take whose finalize failed.
///
/// Split out of `+Take`, which is about the take's lifecycle in this pipeline.
/// The reservation is neither: it is static, shared by every pipeline in the
/// process, and the offload, LUT-import and still-export paths in the app layer
/// claim names through it too.
extension CapturePipeline {
    /// The take's path from the naming template, before the collision suffix.
    func takeFileURL(timecode: Timecode?) -> URL {
        let engine = NamingEngine(template: config.settings.naming.namingTemplate,
                                  clipPadding: config.settings.naming.clipPadWidthEffective)
        let context = NamingContext(
            project: config.settings.naming.projectName,
            date: Date(),
            scene: config.scene,
            take: config.takeNumber,
            reel: config.roll,
            camera: config.settings.naming.cameraLabel,
            postfix: config.settings.naming.postfix ?? "",
            timecode: timecode)
        let root = URL(fileURLWithPath:
            (config.settings.capture.destinationPath as NSString).expandingTildeInPath)
        // write STRAIGHT into the chosen folder — no auto subfolders by date/project:
        // the DIT picks the card/roll folder themselves; app nesting surprises them.
        return root
            .appendingPathComponent(engine.fileName(for: context))
            .appendingPathExtension("mov")
    }

    public static func uniqueURL(for url: URL) -> URL {
        reservationLock.lock()
        defer { reservationLock.unlock() }

        func taken(_ candidate: URL) -> Bool {
            FileManager.default.fileExists(atPath: candidate.path)
                || reservedPaths.contains(candidate.path)
        }

        if !taken(url) {
            reservedPaths.insert(url.path)
            return url
        }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var attempt = 2
        while attempt < 1000 {
            let candidate = URL(fileURLWithPath: base.path + "_\(attempt)")
                .appendingPathExtension(ext)
            if !taken(candidate) {
                reservedPaths.insert(candidate.path)
                return candidate
            }
            attempt += 1
        }
        let fallback = URL(fileURLWithPath: base.path + "_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        reservedPaths.insert(fallback.path)
        return fallback
    }

    /// Drop a reservation once the file exists on disk (or the take failed to
    /// start) — from then on the filesystem itself is the authority.
    public static func releaseReservation(for url: URL) {
        reservationLock.lock()
        reservedPaths.remove(url.path)
        reservationLock.unlock()
    }

    static func markFailed(_ url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.hasSuffix(failedTakeSuffix) else { return url }
        let renamed = url.deletingLastPathComponent()
            .appendingPathComponent(name + failedTakeSuffix)
            .appendingPathExtension(url.pathExtension)
        let target = uniqueURL(for: renamed)
        // `uniqueURL` RESERVES what it hands out, and the reservation is only
        // ever dropped by whoever creates the file. Nothing creates this one:
        // either the move succeeds and the filesystem becomes the authority, or
        // it fails and the name was never used — and an empty take reaches here
        // after `cancel()` has already deleted the file, so that is not a rare
        // branch. Left held, the set grew by one dead path per failure for the
        // life of the process.
        defer { releaseReservation(for: target) }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }
}
