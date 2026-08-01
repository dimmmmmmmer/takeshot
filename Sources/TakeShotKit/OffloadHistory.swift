import CaptureCore
import Foundation

/// One finished offload, as the sheet's history list shows it.
///
/// Deliberately small: what was copied, where it went, how it ended. Not a
/// second copy of the report — the report lives on the destination, and this is
/// the index that says which destination to go and look at.
struct OffloadRunRecord: Codable, Identifiable, Equatable {
    /// How the run ended, in the four states the operator acts on differently.
    /// Stored as its own string rather than derived from the numbers: the
    /// numbers describe one destination and a run can have four.
    enum Verdict: String, Codable {
        case verified
        case problems
        case cancelled
        case failed
    }

    var id: UUID
    var date: Date
    /// The card, by full path — the last component alone is `DCIM` often
    /// enough to be useless.
    var sourcePath: String
    var destinationPaths: [String]
    var verdict: Verdict
    var files: Int
    var filesVerified: Int
    var bytes: Int64

    var sourceName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    var destinationURLs: [URL] {
        destinationPaths.map { URL(fileURLWithPath: $0) }
    }

    init(report: OffloadReport, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.sourcePath = report.run.source.path
        self.destinationPaths = report.destinations.map(\.url.path)
        self.verdict = Self.verdict(of: report)
        self.files = report.run.card.files
        self.filesVerified = report.destinations
            .map(\.totals.filesVerified).min() ?? 0
        self.bytes = report.run.card.bytes
    }

    /// Worst first, the same precedence the summary's verdict line uses: a dead
    /// destination outranks a mismatch, and both outrank a clean stop.
    private static func verdict(of report: OffloadReport) -> Verdict {
        if !report.failedDestinations.isEmpty { return .failed }
        if report.isFullyVerified { return .verified }
        if report.wasCancelled { return .cancelled }
        return .problems
    }
}

/// The log of past offloads, kept between launches.
///
/// **Why it exists.** "Did I already copy this card?" is a question with an
/// expensive wrong answer in both directions — a card wiped twice, or a card
/// carried home unnecessarily — and until now the only place it was written
/// down was on the destination disk, which by then is in a case in a van.
///
/// **Why NOT in the record folder.** The record folder changes with the project
/// and gets emptied, archived or pointed somewhere else between shooting days,
/// and the card being offloaded has nothing to do with it in the first place.
/// The log has to outlive all of that, so it lives with the app's own state in
/// Application Support, next to the LUT library.
@MainActor
final class OffloadHistoryStore: ObservableObject {
    /// How many runs are kept. Twenty is a couple of shooting days' worth of
    /// cards; past that the list is scrolled rather than read, and the reports
    /// on the disks themselves are the real record.
    static let limit = 20

    @Published private(set) var runs: [OffloadRunRecord] = []

    /// Where the log lives. A `var` for the same reason `lutsDirectory` is one:
    /// a test must not read or write the operator's real Application Support,
    /// and the suite points this at its own scratch folder.
    var fileURL: URL = OffloadHistoryStore.defaultURL {
        didSet { load() }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TakeShot/offload-history.json")
    }

    /// Read whatever is on disk.
    ///
    /// A file that will not decode is treated as no history rather than as an
    /// error: this is a convenience index, and refusing to open the offload
    /// sheet because a JSON file from an older build has an extra field would
    /// be the tail wagging the dog.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([OffloadRunRecord].self,
                                                     from: data)
        else {
            runs = []
            return
        }
        runs = Array(stored.prefix(Self.limit))
    }

    /// Newest first, capped, written straight through — a run that finished and
    /// then vanished because the app was quit before some later flush is
    /// exactly the entry somebody would have gone looking for.
    func record(_ report: OffloadReport, at date: Date = Date()) {
        runs = Array(([OffloadRunRecord(report: report, date: date)] + runs)
            .prefix(Self.limit))
        save()
    }

    func clear() {
        runs = []
        save()
    }

    /// Best-effort on purpose, and the one place in the offload path where that
    /// is right: the copies, their manifests and their reports are already on
    /// the destination disks by the time this runs. A read-only Application
    /// Support folder costs the operator a convenience list, not a fact about
    /// footage — and an alarm raised over it would be a false one.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(runs) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
