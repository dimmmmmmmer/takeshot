import Foundation

/// The human-readable report that lands next to the manifest.
///
/// The MHL manifest is for the machine; this is for the person who has to decide
/// whether the card can be wiped. It states the numbers a DIT is asked for on
/// set — what was copied, where from, how much, how fast, with which hash — and
/// ends with a single verdict line that either says every file is verified or
/// names what is not.
///
/// English, like the rest of CaptureCore: the file leaves the building with the
/// drive and is read by whoever receives it, not in the operator's UI language.
public enum OffloadSummary {
    /// What every summary's name starts with. A constant because the verify
    /// tool has to recognize the file it is looking at — a summary reported as
    /// a stray on the disk it was written to is the report accusing itself.
    public static let filePrefix = "offload-summary_"

    @discardableResult
    public static func write(result: OffloadDestinationResult,
                             run: OffloadRunFacts,
                             into destination: URL, date: Date) throws -> URL {
        let name = "\(filePrefix)\(OffloadFormat.fileStamp(date)).txt"
        let url = CapturePipeline.uniqueURL(
            for: destination.appendingPathComponent(name))
        defer { CapturePipeline.releaseReservation(for: url) }
        try Data(text(result: result, run: run).utf8)
            .write(to: url, options: .atomic)
        return url
    }

    public static func text(result: OffloadDestinationResult,
                            run: OffloadRunFacts) -> String {
        var lines = ["TakeShot verified offload",
                     "=========================", ""]
        lines += facts(result: result, run: run)
        lines += ["",
                  "Every file listed in the manifest was written to this disk, "
                    + "flushed to the",
                  "device, read back with the cache bypassed and hashed again. "
                    + "A file whose",
                  "hash did not match is NOT in the manifest and is named below.",
                  ""]
        lines += problems(result: result, run: run)
        lines.append("VERDICT: \(verdict(result: result, run: run))")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - the numbers

    private static func facts(result: OffloadDestinationResult,
                              run: OffloadRunFacts) -> [String] {
        var rows = [
            ("Source", run.source.path),
            ("Destination", result.url.path),
            ("Hash", "\(run.algorithm.displayName) "
                + "(\(run.algorithm.manifestElement))"),
            ("Files", "\(result.totals.filesVerified) of \(run.card.files) "
                + "verified"),
            ("Card size", OffloadFormat.bytes(run.card.bytes)),
            ("Copied", OffloadFormat.bytes(result.totals.bytesWritten)),
            ("Started", OffloadFormat.timestamp(run.span.started)),
            ("Finished", OffloadFormat.timestamp(run.span.finished)),
            ("Elapsed", OffloadFormat.duration(result.totals.elapsed)),
            ("Average", OffloadFormat.rate(result.totals.megabytesPerSecond)),
        ]
        if let manifest = result.manifestURL {
            rows.append(("Manifest",
                         OffloadEngine.relativePath(of: manifest, under: result.url)))
        } else {
            rows.append(("Manifest", "NOT WRITTEN"))
        }
        rows.append(("Written by", "\(run.creator.toolName) "
            + "\(run.creator.toolVersion) on \(run.creator.hostname)"))
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { label, value in
            label + ":" + String(repeating: " ", count: width - label.count + 2)
                + value
        }
    }

    // MARK: - what went wrong

    private static func problems(result: OffloadDestinationResult,
                                 run: OffloadRunFacts) -> [String] {
        var lines: [String] = []
        if let failure = result.failure {
            lines += ["DESTINATION FAILED", "  \(failure)", ""]
        }
        lines += section("CHECKSUM MISMATCHES", result.mismatches)
        lines += section("SOURCE PROBLEMS", run.problems.source)
        // Not "folders": the scan also lands a symlink or a device node here,
        // which cannot be copied as a byte stream. The heading has to cover both
        // or the report says something untrue about what was skipped.
        lines += section("CARD ENTRIES THAT COULD NOT BE COPIED",
                         run.problems.scan)
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
                        run: OffloadRunFacts) -> String {
        let verified = result.totals.filesVerified
        let done = "\(verified) of \(run.card.files) files verified"
        if let failure = result.failure {
            return "FAILED — \(failure) (\(done) before it stopped)"
        }
        if !result.mismatches.isEmpty {
            return "\(result.mismatches.count) FILE(S) DID NOT MATCH — \(done); "
                + "do NOT wipe the card"
        }
        if result.wasCancelled {
            return "CANCELLED — \(done); do NOT wipe the card"
        }
        if verified != run.card.files || !run.problems.isEmpty {
            return "INCOMPLETE — \(done); do NOT wipe the card"
        }
        return "all \(verified) files verified"
    }
}

/// Fixed formatting for everything that goes into a report or a file name.
///
/// Deliberately locale-independent: this text is read by post houses and parsed
/// by eye months later, and a summary whose numbers change shape with the
/// operator's regional settings is not comparable with the last one.
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

    public static func rate(_ megabytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", megabytesPerSecond)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        guard hours > 0 else { return String(format: "%d min %02d s", minutes,
                                             total % 60) }
        return String(format: "%d h %02d min %02d s", hours, minutes, total % 60)
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
