import Foundation

/// **What was done, as a document you can hand over** (owner: "плюс хотелось
/// бы иметь возможность отгружать отчеты проделанной работы по дейликам и по
/// слитым карточкам").
///
/// # What these are, and what they are not
///
/// Two records already exist and neither is this. The offload writes a receipt
/// per RUN — `OffloadSummary`, on the destination disk, answering "can this
/// card be wiped" — and the dailies folder keeps a `DailiesJournal`, which is
/// machine state answering "what is already here". Both are per-thing and both
/// live where the thing is, which by the end of a shift is a disk in a case
/// and a folder on a NAS.
///
/// What is asked for at wrap is neither: it is ONE page saying what the cart
/// did. So these are summaries ACROSS the day's work — every card offloaded,
/// every daily rendered — totalled, with a line each, in the shape the offload
/// receipt already reads in so the family is one family.
///
/// # Why plain text
///
/// It is read on a phone in a van, pasted into an email and printed. The shift
/// report is a table of takes and is a PDF for that reason; this is a dozen
/// lines of totals, and a PDF of a dozen lines is a file somebody has to open
/// an application for. `OffloadSummary` made the same call for the same
/// reader.
///
/// # Nothing here is measured a second time
///
/// Both reports state what the RECORD says, and say so: the dailies half reads
/// the journal, which records what each item produced, and does not open the
/// files. Checking a folder against its journal is `DailiesVerify`, which is a
/// separate action with a separate answer, and folding it in here would make a
/// report that takes minutes to write and re-reads a day of footage to do it.
public enum WorkReport {
    /// One offloaded card, as the report needs it.
    ///
    /// A value of its own rather than the app's own history record: the record
    /// lives in the app layer and carries what its LIST needs (an id for
    /// SwiftUI, paths to re-open), while a report wants exactly these seven
    /// facts. A writer that took the app's type would also have to move with
    /// it every time the list gains a column.
    public struct Card: Sendable, Equatable {
        public var date: Date
        public var source: String
        public var destinations: [String]
        /// The run's own verdict, already decided by whatever recorded it —
        /// `verified`, `problems`, `cancelled`, `failed`. A raw string,
        /// because the report's job is to state what was decided and not to
        /// re-decide it from numbers that describe one destination when a run
        /// can have four.
        public var verdict: String
        public var files: Int
        public var filesVerified: Int
        public var bytes: Int64

        public init(date: Date, source: String, destinations: [String],
                    verdict: String, files: Int, filesVerified: Int,
                    bytes: Int64) {
            self.date = date
            self.source = source
            self.destinations = destinations
            self.verdict = verdict
            self.files = files
            self.filesVerified = filesVerified
            self.bytes = bytes
        }
    }

    /// The dailies rendered into one folder.
    public static func dailies(_ journal: DailiesJournal, folder: URL,
                               labels: WorkReportLabels = .english) -> String {
        let entries = journal.entries.sorted { $0.finishedAt < $1.finishedAt }
        var lines = head(labels.dailiesTitle)
        lines += facts([
            (labels.folder, folder.path),
            (labels.dailies, String(entries.count)),
            (labels.runtime, OffloadFormat.duration(
                entries.reduce(0) { $0 + ($1.outputSeconds ?? 0) },
                labels: labels.offload)),
            (labels.written, OffloadFormat.bytes(
                entries.reduce(0) { $0 + $1.outputSize })),
        ] + span(first: entries.first?.finishedAt,
                 last: entries.last?.finishedAt, labels: labels))
        lines += [""]
        lines += entries.map { entry in
            [OffloadFormat.timestamp(entry.finishedAt),
             "\(entry.source) \u{2192} \(entry.output)",
             entry.outputSeconds.map {
                 OffloadFormat.duration($0, labels: labels.offload)
             } ?? "",
             OffloadFormat.shortBytes(entry.outputSize)]
                .filter { !$0.isEmpty }.joined(separator: "   ")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The cards offloaded.
    public static func cards(_ cards: [Card],
                             labels: WorkReportLabels = .english) -> String {
        let runs = cards.sorted { $0.date < $1.date }
        var lines = head(labels.cardsTitle)
        lines += facts([
            (labels.cards, String(runs.count)),
            (labels.files, OffloadFormat.grouped(
                Int64(runs.reduce(0) { $0 + $1.files }))),
            (labels.copied, OffloadFormat.bytes(
                runs.reduce(0) { $0 + $1.bytes })),
            (labels.verified, String(
                format: labels.verifiedFormat,
                runs.filter { $0.verdict == labels.verifiedVerdict }.count,
                runs.count)),
        ] + span(first: runs.first?.date, last: runs.last?.date,
                 labels: labels))
        lines += [""]
        lines += runs.map { card in
            [OffloadFormat.timestamp(card.date),
             card.source,
             String(format: labels.filesOfFormat, card.filesVerified,
                    card.files),
             OffloadFormat.shortBytes(card.bytes),
             "\u{2192} " + destinations(card.destinations, labels: labels),
             labels.verdict(card.verdict)]
                .joined(separator: "   ")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A title with a rule under it, derived from the title so a longer
    /// translation stays underlined edge to edge — `OffloadSummary`'s own
    /// arrangement, because these are the same piece of paper's family.
    private static func head(_ title: String) -> [String] {
        [title, String(repeating: "=", count: title.count), ""]
    }

    /// The label/value block, with the labels padded into a column.
    private static func facts(_ rows: [(String, String)]) -> [String] {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { label, value in
            label.padding(toLength: max(width, label.count), withPad: " ",
                          startingAt: 0) + "   " + value
        }
    }

    /// The two ends of the work, or nothing at all when there was none — a
    /// report of an empty folder must not print the epoch as its first item.
    private static func span(first: Date?, last: Date?,
                             labels: WorkReportLabels) -> [(String, String)] {
        guard let first, let last else { return [] }
        return [(labels.first, OffloadFormat.timestamp(first)),
                (labels.last, OffloadFormat.timestamp(last))]
    }

    /// Where a card went. The paths themselves for one or two disks, and a
    /// count past that: a run to five disks would otherwise put five absolute
    /// paths on one line and make the column unreadable for every other row.
    private static func destinations(_ paths: [String],
                                     labels: WorkReportLabels) -> String {
        guard paths.count > 2 else {
            return paths.isEmpty ? "\u{2014}" : paths.joined(separator: ", ")
        }
        return String(format: labels.destinationsFormat, paths.count)
    }
}

/// The work reports' translatable words. Injected by the app in its UI
/// language, like every other report CaptureCore writes; the English default
/// is what these files say with no app around them.
public struct WorkReportLabels: Sendable, Equatable {
    public var dailiesTitle = "TakeShot — dailies work report"
    public var cardsTitle = "TakeShot — card work report"
    public var folder = "Folder"
    public var dailies = "Dailies"
    public var runtime = "Runtime"
    public var written = "Written"
    public var cards = "Cards"
    public var files = "Files"
    public var copied = "Copied"
    public var verified = "Verified"
    public var first = "First"
    public var last = "Last"
    /// "4 of 6" — how many runs came back fully verified.
    public var verifiedFormat = "%1$d of %2$d"
    /// The same shape per row, counting FILES rather than runs.
    public var filesOfFormat = "%1$d of %2$d files"
    public var destinationsFormat = "%d disks"
    /// The four run verdicts, keyed by the raw value the record carries.
    public var verdicts = ["verified": "verified", "problems": "problems",
                           "cancelled": "cancelled", "failed": "failed"]
    /// Which raw verdict counts as a clean run — stated rather than assumed,
    /// so the tally and the words cannot come to disagree about it.
    public var verifiedVerdict = "verified"
    /// The duration units, which `OffloadFormat.duration` needs and which the
    /// offload report already translates. Carried rather than re-declared:
    /// two reports from one cart must not spell "min" two ways.
    public var offload = OffloadReportLabels.english

    public init() {}

    public static let english = WorkReportLabels()

    /// A verdict in the report's language, falling back to the raw value — a
    /// verdict added later renders as itself rather than as a blank cell.
    public func verdict(_ raw: String) -> String { verdicts[raw] ?? raw }
}
