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
            recordedAt: created)
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
        return EmbeddedMetadata(
            roll: await value(TakeWriter.rollKey) ?? "",
            takeNumber: Int(await value(TakeWriter.clipKey) ?? "") ?? 0,
            scene: await value(TakeWriter.sceneKey),
            shot: await value(TakeWriter.shotKey),
            take: await value(TakeWriter.takeKey),
            durationSeconds: duration,
            startTimecode: startTC)
    }

    /// The slate as the file itself carries it. A take key of 0 or nonsense is
    /// dropped rather than trusted: a hand-tagged file must not put a take
    /// number the slate never had into the day's log.
    private func embeddedSlate(scene: String?, shot: String?,
                               take: String?) -> SlateMetadata {
        SlateMetadata(scene: scene ?? "", shot: shot ?? "",
                      take: max(0, Int(take ?? "") ?? 0))
    }
    /// Ratings, comments, markers and slates of the day, as saved next to the
    /// takes. The markers stay unresolved rows here: their position is a
    /// timecode in the sidecar, and turning it into an offset needs the take's
    /// own start TC, which is only read further down in `classify`.
    func loadStoredMetadata() -> StoredSidecars {
        // Lossy decode on purpose: one bad byte must not wipe the day's
        // ratings. The failable String(bytes:encoding:) the linter prefers
        // would return nil for the whole file, which is exactly the outcome
        // this guards against.
        // swiftlint:disable optional_data_string_conversion
        let meta = (try? Data(contentsOf: takeLogURL))
            .map { TakeLogExporter.parseMetadata(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        let markersURL = destinationRoot
            .appendingPathComponent(TakeLogExporter.markersFileName)
        let markers = (try? Data(contentsOf: markersURL))
            .map { TakeLogExporter.parseMarkerRows(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        let slatesURL = destinationRoot
            .appendingPathComponent(TakeLogExporter.slateFileName)
        let slates = (try? Data(contentsOf: slatesURL))
            .map { TakeLogExporter.parseSlates(
                csv: String(decoding: $0, as: UTF8.self)) } ?? [:]
        // swiftlint:enable optional_data_string_conversion
        return StoredSidecars(meta: meta, markers: markers, slates: slates)
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
