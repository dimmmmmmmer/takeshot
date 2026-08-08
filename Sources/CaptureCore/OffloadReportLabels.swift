import Foundation

/// Every user-facing label the two offload deliverables carry — the summary
/// .txt and the report-card PNG — as one injectable value.
///
/// CaptureCore is deliberately localization-free (no bundle, no `L()`): the
/// engine must stay testable without an app around it, and a language switch is
/// UI state. So the app injects the labels in the operator's language through
/// `OffloadPlan`, and everything here DEFAULTS to the exact English the reports
/// have always used — a plan built without labels writes byte-identical
/// reports, which is what the pinned summary test holds.
///
/// What is translated is the labels; what is NOT is the data between them.
/// Mismatch reasons, file paths and error strings come out of the engine in
/// English, and unit symbols that are SI (kB/MB/GB, MB/s) stay Latin — they are
/// how drives and every DIT tool quote them in any language. The worded
/// duration units (h/min/s) are language, so they are fields here.
public struct OffloadReportLabels: Sendable, Equatable {
    // MARK: - summary .txt

    /// First line of the summary; the `===` rule under it follows its length.
    public var title = "TakeShot verified offload"
    public var source = "Source"
    public var destination = "Destination"
    public var hash = "Hash"
    public var files = "Files"
    public var cardSize = "Card size"
    public var copied = "Copied"
    public var started = "Started"
    public var finished = "Finished"
    public var elapsed = "Elapsed"
    public var average = "Average"
    public var manifest = "Manifest"
    public var manifestMissing = "NOT WRITTEN"
    /// The row a RESUMED run adds, and only such a run (see `OffloadResume`).
    public var resumed = "Resumed"
    /// Files reused, how much that was, and how many were copied again instead
    /// of trusted — "400 files (61.0 GB) already here and re-verified, 1 re-copied".
    public var resumedFormat
        = "%d files (%@) already here and re-verified, %d re-copied"
    public var writtenBy = "Written by"
    /// Tool, version, host — "TakeShot 1.0 on studio-mac.local".
    public var writtenByFormat = "%@ %@ on %@"
    /// The Files row's value — "3 of 3 verified".
    public var filesVerifiedFormat = "%d of %d verified"
    /// The paragraph that states what "verified" means here. Line breaks are
    /// part of the value: the .txt is read in a terminal at 80 columns.
    public var explanation = "Every file listed in the manifest was written to "
        + "this disk, flushed to the\ndevice, read back with the cache bypassed "
        + "and hashed again. A file whose\nhash did not match is NOT in the "
        + "manifest and is named below."

    // MARK: - problem sections (shared by the .txt and the card)

    public var destinationFailedHeading = "DESTINATION FAILED"
    /// Copies that were already on this disk where a file had to be written, and
    /// were replaced from the card rather than trusted.
    public var replacedHeading = "RE-COPIED OVER AN INTERRUPTED RUN"
    public var mismatchesHeading = "CHECKSUM MISMATCHES"
    public var sourceProblemsHeading = "SOURCE PROBLEMS"
    public var scanProblemsHeading = "CARD ENTRIES THAT COULD NOT BE COPIED"

    // MARK: - the verdict (shared: the .txt states it, the card draws it)

    public var verdictLabel = "VERDICT"
    /// "1 of 3 files verified" — the count every verdict below embeds.
    public var filesOfTotalFormat = "%d of %d files verified"
    public var verdictFailedFormat = "FAILED — %@ (%@ before it stopped)"
    public var verdictMismatchFormat
        = "%d FILE(S) DID NOT MATCH — %@; do NOT wipe the card"
    public var verdictCancelledFormat = "CANCELLED — %@; do NOT wipe the card"
    public var verdictIncompleteFormat = "INCOMPLETE — %@; do NOT wipe the card"
    public var verdictAllVerifiedFormat = "all %d files verified"

    // MARK: - report-card PNG

    public var brand = "TAKESHOT — VERIFIED OFFLOAD"
    public var statFiles = "FILES"
    public var statCopied = "COPIED"
    public var statTime = "TIME"
    public var statSpeed = "SPEED"
    /// The FILES stat's value — "3 of 3".
    public var statFilesFormat = "%d of %d"
    /// Heading over the card's problem list; the count is appended as "(n)".
    public var problemsHeading = "PROBLEMS"
    /// Tool, version, host, checksum name, checksum-list path — the card's
    /// one-line footer. It does NOT call the manifest the receipt: the receipt
    /// is this card and the .txt beside it, in the root of the copy (owner
    /// item 24).
    public var footerFormat
        = "%@ %@ on %@   ·   %@   ·   checksum list: %@"
    public var checksumListMissing = "not written"
    /// A dead destination, as the card's problem list words it.
    public var destinationFailedLineFormat = "Destination failed — %@"
    /// The line that stands in for the problems the card had no room for.
    public var moreProblemsFormat = "…and %d more — see the .txt summary"

    // MARK: - worded duration units (see `OffloadFormat.duration`)

    public var hoursUnit = "h"
    public var minutesUnit = "min"
    public var secondsUnit = "s"

    public init() {}

    /// The default — what every report said before the labels were injectable.
    public static let english = OffloadReportLabels()
}
