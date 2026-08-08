import Foundation

/// The human-readable report that lands next to the manifest.
///
/// The MHL manifest is for the machine; this is for the person who has to decide
/// whether the card can be wiped. It states the numbers a DIT is asked for on
/// set — what was copied, where from, how much, how fast, with which hash — and
/// ends with a single verdict line that either says every file is verified or
/// names what is not.
///
/// The labels come in from the app in the operator's language (owner item 21 —
/// the report used to be English whatever language the app was set to);
/// CaptureCore itself stays localization-free, so the default is the English
/// the file has always used. The DATA between the labels — paths, mismatch
/// reasons, engine errors — stays English; see `OffloadReportLabels`.
///
/// It is written into the ROOT of the copy, next to the footage rather than in
/// a folder of its own (owner item 24) — the person it is for opens the copy
/// and it is there. The `ascmhl/` manifest beside it is the one artifact that
/// does live in a subfolder, because the spec puts it there (see `OffloadMHL`).
public enum OffloadSummary {
    /// What every summary's name starts with. A constant because the verify
    /// tool has to recognize the file it is looking at — a summary reported as
    /// a stray on the disk it was written to is the report accusing itself.
    public static let filePrefix = "offload-summary_"

    @discardableResult
    public static func write(result: OffloadDestinationResult,
                             run: OffloadRunFacts,
                             into destination: URL, date: Date,
                             labels: OffloadReportLabels = .english) throws -> URL {
        let name = "\(filePrefix)\(OffloadFormat.fileStamp(date)).txt"
        let url = CapturePipeline.uniqueURL(
            for: destination.appendingPathComponent(name))
        defer { CapturePipeline.releaseReservation(for: url) }
        try Data(text(result: result, run: run, labels: labels).utf8)
            .write(to: url, options: .atomic)
        return url
    }

    public static func text(result: OffloadDestinationResult,
                            run: OffloadRunFacts,
                            labels: OffloadReportLabels = .english) -> String {
        // the rule is derived from the title, so a longer translation of it
        // stays underlined edge to edge
        var lines = [labels.title,
                     String(repeating: "=", count: labels.title.count), ""]
        lines += facts(result: result, run: run, labels: labels)
        lines += [""]
        lines += labels.explanation.components(separatedBy: "\n")
        lines += [""]
        lines += problems(result: result, run: run, labels: labels)
        lines.append("\(labels.verdictLabel): "
            + verdict(result: result, run: run, labels: labels))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - the numbers

    private static func facts(result: OffloadDestinationResult,
                              run: OffloadRunFacts,
                              labels: OffloadReportLabels) -> [String] {
        var rows = [
            (labels.source, run.source.path),
            (labels.destination, result.url.path),
            (labels.hash, "\(run.algorithm.displayName) "
                + "(\(run.algorithm.manifestElement))"),
            (labels.files, String(format: labels.filesVerifiedFormat,
                                  result.totals.filesVerified, run.card.files)),
            (labels.cardSize, OffloadFormat.bytes(run.card.bytes)),
            (labels.copied, OffloadFormat.bytes(result.totals.bytesWritten)),
            (labels.started, OffloadFormat.timestamp(run.span.started)),
            (labels.finished, OffloadFormat.timestamp(run.span.finished)),
            (labels.elapsed, OffloadFormat.duration(result.totals.elapsed,
                                                    labels: labels)),
            (labels.average, OffloadFormat.rate(result.totals.megabytesPerSecond)),
        ]
        // Only on a run that was ASKED to resume, which is what keeps every
        // other summary byte-identical to the one this file has always written.
        // A run that asked and was refused says so here too: "everything was
        // copied" without the reason is the line that gets a tool distrusted.
        if let resume = result.resume {
            rows.append((labels.resumed, resume.refusal
                ?? String(format: labels.resumedFormat, resume.reused,
                          OffloadFormat.shortBytes(resume.reusedBytes),
                          resume.replaced.count)))
        }
        if let manifest = result.manifestURL {
            rows.append((labels.manifest,
                         OffloadEngine.relativePath(of: manifest, under: result.url)))
        } else {
            rows.append((labels.manifest, labels.manifestMissing))
        }
        rows.append((labels.writtenBy,
                     String(format: labels.writtenByFormat, run.creator.toolName,
                            run.creator.toolVersion, run.creator.hostname)))
        // padded to the longest label of THIS language, so the value column
        // stays a column whatever the translations measure
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { label, value in
            label + ":" + String(repeating: " ", count: width - label.count + 2)
                + value
        }
    }

    // MARK: - what went wrong

    private static func problems(result: OffloadDestinationResult,
                                 run: OffloadRunFacts,
                                 labels: OffloadReportLabels) -> [String] {
        var lines: [String] = []
        if let failure = result.failure {
            lines += [labels.destinationFailedHeading, "  \(failure)", ""]
        }
        // Not a problem — the feature working — but it is a set of files that
        // were on this disk and are not the ones on it now, and that is never
        // something to leave unsaid.
        lines += section(labels.replacedHeading, result.resume?.replaced ?? [])
        lines += section(labels.mismatchesHeading, result.mismatches)
        lines += section(labels.sourceProblemsHeading, run.problems.source)
        // Not "folders": the scan also lands a symlink or a device node here,
        // which cannot be copied as a byte stream. The heading has to cover both
        // or the report says something untrue about what was skipped.
        lines += section(labels.scanProblemsHeading, run.problems.scan)
        return lines
    }

    private static func section(_ title: String, _ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        return ["\(title) (\(items.count))"] + items.map { "  \($0)" } + [""]
    }

    /// One line, and it has to be readable by someone deciding whether to wipe a
    /// card. Precedence is worst-first: a dead destination is a bigger fact than
    /// a mismatch, and both are bigger than a clean cancel.
    static func verdict(result: OffloadDestinationResult,
                        run: OffloadRunFacts,
                        labels: OffloadReportLabels = .english) -> String {
        let verified = result.totals.filesVerified
        let done = String(format: labels.filesOfTotalFormat, verified,
                          run.card.files)
        if let failure = result.failure {
            return String(format: labels.verdictFailedFormat, failure, done)
        }
        if !result.mismatches.isEmpty {
            return String(format: labels.verdictMismatchFormat,
                          result.mismatches.count, done)
        }
        if result.wasCancelled {
            return String(format: labels.verdictCancelledFormat, done)
        }
        if verified != run.card.files || !run.problems.isEmpty {
            return String(format: labels.verdictIncompleteFormat, done)
        }
        return String(format: labels.verdictAllVerifiedFormat, verified)
    }
}

/// Fixed formatting for everything that goes into a report or a file name.
///
/// Deliberately locale-independent: this text is read by post houses and parsed
/// by eye months later, and a summary whose numbers change shape with the
/// operator's regional settings is not comparable with the last one. The one
/// language-dependent part — the worded duration units — comes in through the
/// report labels; the SI unit symbols (kB/MB/GB, MB/s) stay Latin everywhere.
public enum OffloadFormat {
    /// Decimal units, as drives and offload tools quote them.
    public static func bytes(_ count: Int64) -> String {
        let units = [("TB", 1_000_000_000_000.0), ("GB", 1_000_000_000.0),
                     ("MB", 1_000_000.0), ("kB", 1000.0)]
        let value = Double(count)
        for (suffix, scale) in units where value >= scale {
            return String(format: "%.1f %@ (%@ bytes)", value / scale, suffix,
                          grouped(count))
        }
        return "\(count) bytes"
    }

    /// `12,345,678` — thousands separated, without a NumberFormatter's locale.
    public static func grouped(_ count: Int64) -> String {
        let digits = Array(String(count.magnitude))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (count < 0 ? "-" : "") + out
    }

    /// `32.0 GB`, without the exact byte count `bytes` appends.
    ///
    /// For anywhere the number is a headline rather than an audit: the report
    /// card's stat row, and the free/used line on the offload sheet's tiles.
    /// The parenthesis is for the .txt, where somebody is checking arithmetic.
    public static func shortBytes(_ count: Int64) -> String {
        let full = bytes(count)
        return full.components(separatedBy: " (").first ?? full
    }

    public static func rate(_ megabytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", megabytesPerSecond)
    }

    /// "15 min 30 s" — the unit WORDS follow the report's language, because
    /// they are words; everything numeric about the shape stays fixed.
    public static func duration(_ seconds: TimeInterval,
                                labels: OffloadReportLabels = .english) -> String {
        guard seconds >= 60 else {
            return String(format: "%.1f %@", seconds, labels.secondsUnit)
        }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        guard hours > 0 else {
            return String(format: "%d %@ %02d %@", minutes, labels.minutesUnit,
                          total % 60, labels.secondsUnit)
        }
        return String(format: "%d %@ %02d %@ %02d %@", hours, labels.hoursUnit,
                      minutes, labels.minutesUnit, total % 60, labels.secondsUnit)
    }

    public static func timestamp(_ date: Date) -> String {
        formatter(with: "yyyy-MM-dd HH:mm:ss Z").string(from: date)
    }

    /// For file names: no spaces, no colons (a colon is a path separator in the
    /// Finder's eyes and turns into a slash).
    public static func fileStamp(_ date: Date) -> String {
        formatter(with: "yyyy-MM-dd_HHmmss").string(from: date)
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func formatter(with format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // POSIX: a Russian or Japanese system locale must not reformat the
        // report, and a non-Gregorian calendar must not renumber the year.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}
