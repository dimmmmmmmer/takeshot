import AVFoundation
import CaptureCore
import Foundation

/// Whether a file the scan found is one of ours, and the sidecars a take is
/// rebuilt from when it is.
///
/// Split out of `+LibraryScan`: running the pass and deciding what one file IS
/// are separate jobs, and this one is where a take recovers the operator's own
/// work — the rating, the comment and the markers live beside the footage, not
/// inside it.
extension CaptureController {
    /// The day's sidecars, read once per scan and keyed by file name. A named
    /// type rather than a tuple: there are three of them now, they are all
    /// dictionaries of file name to something, and positional members of that
    /// shape are indistinguishable at the call site.
    struct StoredSidecars {
        var meta: [String: TakeLogExporter.TakeMeta] = [:]
        var markers: [String: [TakeLogExporter.MarkerRow]] = [:]
        var slates: [String: TakeLogExporter.SlateRow] = [:]
        /// A sidecar that IS there and could not be read, with what the file
        /// system said. Empty when every file was either read or absent.
        ///
        /// **Absent and unreadable are different answers and were not being
        /// told apart.** Both came back as an empty table, and the next rating
        /// or take rewrites the whole table from memory — so a record folder on
        /// a share that had not finished mounting, or a card with an I/O error
        /// on one file, lost the day's ratings, comments, markers and slates
        /// without a word. The write side has called this "a day-loss bug" in
        /// its own catch since it was written; the read side had no equivalent.
        var unreadable: [String] = []
    }

    /// What the file itself carries, reduced to values that can leave the
    /// load. The counterpart of `StoredSidecars`: that is what the day's CSVs
    /// say about a take, this is what the .mov says about itself.
    ///
    /// A named Sendable type rather than the items themselves, because an
    /// `AVMetadataItem` is not `Sendable` in any macOS SDK and so cannot cross
    /// back to the main actor at all. Reading them where they are produced and
    /// answering there is the only shape that is right under every SDK's
    /// annotations — and it costs the scan one suspension per file instead of
    /// eight.
    struct EmbeddedMetadata: Sendable {
        var roll: String
        var takeNumber: Int
        var scene: String?
        var shot: String?
        var take: String?
        var durationSeconds: Double
        var startTimecode: Timecode?
        /// From `com.takeshot.framerate` when this build wrote the file, else
        /// the video track's own nominal rate — a take from an older build
        /// still gets its 23.976 back rather than the timecode's 24.
        var frameRate: Double?
    }

    /// Identify one candidate, restoring its take metadata when it is ours.
    func classify(_ url: URL,
                  stored: StoredSidecars) async -> ScanOutcome {
        if scannedPaths.contains(url.path) {
            return takes.contains(where: { $0.url.path == url.path })
                ? .known : .foreign
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "mov" || ext == "mp4",
              !Self.isCinemaDNGFolder(url) else {
            scannedPaths.insert(url.path)
            return .foreign
        }
        // A take whose finalize failed is renamed `*_FAILED.mov` precisely so it
        // cannot pass for good footage — and the rename alone does not achieve
        // that. `movieFragmentInterval` means the half-written file already has a
        // moov carrying `com.takeshot.origin`, so the check below recognised it
        // and the very next folder scan adopted it back into the takes list, from
        // there into `takeshot-log.csv`, which is what post-production reads.
        // It stays VISIBLE, as Other content: with fragmented atoms most of such
        // a file is usually recoverable and deleting it is not this app's call.
        // `contains` rather than `hasSuffix` — a second failure of the same name
        // comes out as `..._FAILED_2.mov`, the same reading the diagnostics
        // bundle's own flag uses.
        if url.deletingPathExtension().lastPathComponent
            .contains(CapturePipeline.failedTakeSuffix) {
            scannedPaths.insert(url.path)
            return .foreign
        }
        if let refused = refuseLedgeredFailure(url) { return refused }
        let embedded = await Self.embeddedMetadata(of: url)
        scannedPaths.insert(url.path)
        guard let embedded else {
            return .foreign
        }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? Date.distantPast
        let name = url.lastPathComponent
        var take = Take(
            url: url,
            scene: "",
            roll: embedded.roll,
            takeNumber: embedded.takeNumber,
            startTimecode: embedded.startTimecode,
            durationSeconds: embedded.durationSeconds,
            recordedAt: created,
            frameRate: embedded.frameRate)
        // the operator's own work, restored from the sidecars rather than read
        // off the file
        take.rating = stored.meta[name]?.rating ?? .none
        take.comment = stored.meta[name]?.comment ?? ""
        take.markers = TakeLogExporter.markers(stored.markers[name] ?? [],
                                               of: take)
        // The creative fields are the one thing that lives in BOTH places. The
        // sidecar wins because it is the only one a correction can reach (see
        // CaptureController+Slate); the file's own keys are the fallback, and
        // they are what makes a .mov copied away from its sidecars still know
        // which scene it is — the whole point of embedding them.
        take.slate = embeddedSlate(scene: embedded.scene, shot: embedded.shot,
                                   take: embedded.take)
        if let row = stored.slates[name] {
            take.slate = row.slate
            take.logDescription = row.logDescription
        }
        return .take(take)
    }

    /// Everything one candidate file says about itself, in one nonisolated
    /// pass. `nil` means it is not ours: the marker key is what a TakeShot
    /// recording is identified by, and a file without it is Other content and
    /// is not read any further — the same early out this had when the keys
    /// were pulled one await at a time.
    nonisolated private static func embeddedMetadata(
        of url: URL) async -> EmbeddedMetadata? {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        func value(_ key: String) async -> String? {
            guard let item = metadata.first(where: { ($0.key as? String) == key })
            else { return nil }
            return try? await item.load(.stringValue)
        }
        guard await value(TakeWriter.markerKey) != nil else { return nil }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let startTC = await TimecodeReader.startTimecode(of: asset)
        var frameRate = Double(await value(TakeWriter.frameRateKey) ?? "")
        if frameRate == nil,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            let nominal = try? await track.load(.nominalFrameRate)
            if let nominal, nominal > 0 { frameRate = Double(nominal) }
        }
        return EmbeddedMetadata(
            roll: await value(TakeWriter.rollKey) ?? "",
            takeNumber: Int(await value(TakeWriter.clipKey) ?? "") ?? 0,
            scene: await value(TakeWriter.sceneKey),
            shot: await value(TakeWriter.shotKey),
            take: await value(TakeWriter.takeKey),
            durationSeconds: duration,
            startTimecode: startTC,
            frameRate: frameRate)
    }

    /// The slate as the file itself carries it. A take key of 0 or nonsense is
    /// dropped rather than trusted: a hand-tagged file must not put a take
    /// number the slate never had into the day's log.
    private func embeddedSlate(scene: String?, shot: String?,
                               take: String?) -> SlateMetadata {
        SlateMetadata(scene: scene ?? "",
                      shot: SlateTakeField.number(from: shot ?? ""),
                      take: max(0, Int(take ?? "") ?? 0))
    }
    /// Ratings, comments, markers and slates of the day, as saved next to the
    /// takes. The markers stay unresolved rows here: their position is a
    /// timecode in the sidecar, and turning it into an offset needs the take's
    /// own start TC, which is only read further down in `classify`.
    func loadStoredMetadata() -> StoredSidecars {
        var sidecars = StoredSidecars()
        let markersURL = destinationRoot
            .appendingPathComponent(TakeLogExporter.markersFileName)
        let slatesURL = destinationRoot
            .appendingPathComponent(TakeLogExporter.slateFileName)

        // Lossy DECODE on purpose: one bad byte must not wipe the day's
        // ratings, so the bytes that arrive are always turned into a string.
        // What is not lossy any more is the READ — see `StoredSidecars`.
        // swiftlint:disable optional_data_string_conversion
        switch Self.readSidecar(takeLogURL) {
        case .absent: break
        case .read(let data):
            sidecars.meta = TakeLogExporter.parseMetadata(
                csv: String(decoding: data, as: UTF8.self))
        case .unreadable(let why): sidecars.unreadable.append(why)
        }
        switch Self.readSidecar(markersURL) {
        case .absent: break
        case .read(let data):
            sidecars.markers = TakeLogExporter.parseMarkerRows(
                csv: String(decoding: data, as: UTF8.self))
        case .unreadable(let why): sidecars.unreadable.append(why)
        }
        switch Self.readSidecar(slatesURL) {
        case .absent: break
        case .read(let data):
            sidecars.slates = TakeLogExporter.parseSlates(
                csv: String(decoding: data, as: UTF8.self))
        case .unreadable(let why): sidecars.unreadable.append(why)
        }
        // swiftlint:enable optional_data_string_conversion
        return sidecars
    }

    /// What came back from one sidecar: nothing there, the bytes, or a reason.
    enum SidecarRead {
        /// No such file — the ordinary state of a fresh record folder.
        case absent
        case read(Data)
        /// It is there and would not open. Carries the sentence to show.
        case unreadable(String)
    }

    /// One sidecar, with "not there" told apart from "would not open".
    ///
    /// The distinction is the whole point: nothing there is the first take of
    /// the day, and a file that IS there and will not open is a folder whose
    /// contents must not be overwritten from memory.
    ///
    /// **Asked as "does this file exist", not by matching an error code.** The
    /// first version matched `NSFileReadNoSuchFileError` and treated every
    /// other error as unreadable — and a path whose PARENT is gone does not
    /// give that error: a record folder blocked by a regular file answers
    /// `NSFileReadUnknownError` (256), so a vanished record volume looked like
    /// three unreadable sidecars. That put "the day's ratings are not being
    /// saved" on the banner over `alarm_volume_unreachable`, which is the more
    /// serious fault and the one the operator has to act on. CI caught it; the
    /// development Mac did not.
    ///
    /// Existence is also the more honest question. A file that is not there for
    /// ANY reason — no folder, no volume, no permission to look — is not a
    /// sidecar this app is about to overwrite, because the write will fail too
    /// and `exportTakeLog`'s catch already reports that.
    static func readSidecar(_ url: URL) -> SidecarRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        do {
            return .read(try Data(contentsOf: url))
        } catch {
            return .unreadable(L("sidecar_unreadable",
                                 url.lastPathComponent,
                                 error.localizedDescription))
        }
    }
    /// Markers on clips that are not ours, back from the same sidecar.
    ///
    /// Restricted to the files the scan actually found, and to the ones the
    /// session does not already know — the same two rules `restoreRanges` keeps,
    /// and for the same reasons: a row for a clip that has been trashed must not
    /// come back from a sidecar written before it went, and a scan runs every
    /// minute, so it must never undo a marker the operator just placed.
    ///
    /// Such a clip has no timecode track we read, so its rows are offsets from
    /// zero on both sides of the file (see `markerTimecode(of:startingAt:)`);
    /// the duration is unknown here, which only means nothing is vetoed for
    /// being past the end.
    func restoreOtherMarkers(_ stored: [String: [TakeLogExporter.MarkerRow]],
                             forFilesNamed names: Set<String>) {
        for (name, rows) in stored
        where names.contains(name) && otherMarkers[name] == nil {
            let markers = TakeLogExporter.markers(rows, startingAt: nil,
                                                  duration: 0)
            guard !markers.isEmpty else { continue }
            otherMarkers[name] = markers
        }
    }

    /// Loop ranges of the day, as saved next to the takes. Read separately from
    /// the ratings and markers above because the consumer is different — these go
    /// to the transport, not onto a `Take`.
    func loadStoredRanges() -> [String: ClipRange] {
        let url = destinationRoot
            .appendingPathComponent(TakeLogExporter.rangesFileName)
        // Lossy for the same reason as the metadata CSV: one bad byte in a file
        // the DIT may have opened in Excel must not cost every range in it. The
        // failable initializer the linter prefers returns nil for the whole file,
        // which is the outcome this guards against.
        // swiftlint:disable optional_data_string_conversion
        let ranges = (try? Data(contentsOf: url))
            .map { TakeLogExporter.parseRanges(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        // swiftlint:enable optional_data_string_conversion
        return ranges
    }
}

extension CaptureController {
    /// What the scan found out about the sidecars, turned into the latch that
    /// guards `exportTakeLog` and the banner that says why.
    ///
    /// The banner is the STICKY register and not a toast: the operator's
    /// ratings and comments are not being saved, and a five-second message
    /// about that is one they can be looking away from. It clears itself when a
    /// later scan reads the files — a share that finished mounting fixes this
    /// without anybody being told twice.
    func noteUnreadableSidecars(_ reasons: [String]) {
        let previous = unreadableSidecars
        unreadableSidecars = reasons
        guard previous != reasons else { return }
        if reasons.isEmpty {
            // Only our own banner: anything else on it outranks a fault that
            // has just resolved itself.
            if persistentAlert == Self.sidecarAlert(previous) { persistentAlert = nil }
            // The edits made while the folder was unreadable were kept in
            // memory and never written; now that it opens, write them.
            exportTakeLog()
        } else {
            persistentAlert = Self.sidecarAlert(reasons)
        }
    }

    static func sidecarAlert(_ reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        return ([L("sidecars_not_rewritten")] + reasons).joined(separator: "\n")
    }
}

extension CaptureController {
    /// A failed take whose rename could not be made when the volume dropped
    /// still carries the healthy name and the origin tag. The ledger is what
    /// survived the drop; it is asked before the tag is trusted, and the rename
    /// is tried again now that the file is reachable — success makes the NAME
    /// say it, and the entry goes. nil for a file the ledger has never heard of.
    func refuseLedgeredFailure(_ url: URL) -> ScanOutcome? {
        guard FailedTakeLedger.contains(url) else { return nil }
        let marked = CapturePipeline.markFailed(url)
        scannedPaths.insert(url.path)
        // Still cannot be renamed: visible as Other content under its healthy
        // name, never a take. Renamed: the old path is gone, and the `_FAILED`
        // file is picked up by the name guard on the next scan.
        return marked == url ? .foreign : .known
    }
}
