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
    /// Identify one candidate, restoring its take metadata when it is ours.
    func classify(
        _ url: URL,
        stored: (meta: [String: TakeLogExporter.TakeMeta],
                 markers: [String: [TakeLogExporter.MarkerRow]])) async -> ScanOutcome {
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
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        func value(_ key: String) async -> String? {
            guard let item = metadata.first(where: { ($0.key as? String) == key })
            else { return nil }
            return try? await item.load(.stringValue)
        }
        scannedPaths.insert(url.path)
        guard await value(TakeWriter.markerKey) != nil else {
            return .foreign
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? Date.distantPast
        let startTC = await TimecodeReader.startTimecode(of: asset)
        let name = url.lastPathComponent
        var take = Take(
            url: url,
            scene: "",
            roll: await value(TakeWriter.rollKey) ?? "",
            takeNumber: Int(await value(TakeWriter.clipKey) ?? "") ?? 0,
            startTimecode: startTC,
            durationSeconds: duration,
            recordedAt: created)
        // the operator's own work, restored from the sidecars rather than read
        // off the file
        take.rating = stored.meta[name]?.rating ?? .none
        take.comment = stored.meta[name]?.comment ?? ""
        take.markers = TakeLogExporter.markers(stored.markers[name] ?? [],
                                               of: take)
        return .take(take)
    }
    /// Ratings, comments and markers of the day, as saved next to the takes.
    /// The markers stay unresolved rows here: their position is a timecode in
    /// the sidecar, and turning it into an offset needs the take's own start TC,
    /// which is only read further down in `classify`.
    func loadStoredMetadata()
        -> (meta: [String: TakeLogExporter.TakeMeta],
            markers: [String: [TakeLogExporter.MarkerRow]]) {
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
        // swiftlint:enable optional_data_string_conversion
        return (meta, markers)
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
