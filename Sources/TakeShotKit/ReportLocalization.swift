import CaptureCore
import Foundation

// The bridge between the app's language switch and the reports CaptureCore
// writes (owner item 21). CaptureCore is deliberately localization-free, so
// each of its report writers takes a labels value; these builders fill those
// values through `L()` at the moment a report is made — which is what makes a
// report follow the language the app is set to right then, not the one it
// launched with.

extension ShiftReportCSVLabels {
    /// The shift-report CSV's words in the current UI language. The frozen
    /// Resolve sidecar (`takeshot-log.csv`) has no builder on purpose — its
    /// schema is machine-read and never translated.
    static func current() -> ShiftReportCSVLabels {
        var labels = ShiftReportCSVLabels()
        labels.header = [L("report_csv_file"), L("report_csv_roll"),
                         L("report_csv_clip"), L("report_csv_scene"),
                         L("report_csv_shot"), L("report_csv_take"),
                         L("report_csv_start"), L("report_csv_end"),
                         L("report_csv_duration"), L("report_csv_rating"),
                         L("report_csv_comments"),
                         L("report_csv_description"),
                         L("report_csv_markers"), L("report_csv_recorded")]
        labels.good = L("report_rating_good")
        labels.bad = L("report_rating_bad")
        return labels
    }
}

extension OffloadReportLabels {
    /// The offload summary's and report card's words in the current UI
    /// language. Read once per run and stamped into the plan — the reports of
    /// one run must all speak one language even if the operator flips the
    /// switch while it copies.
    static func current() -> OffloadReportLabels {
        var labels = OffloadReportLabels()
        labels.title = L("offload_report_title")
        labels.source = L("offload_report_source")
        labels.destination = L("offload_report_destination")
        labels.hash = L("offload_report_hash")
        labels.files = L("offload_report_files")
        labels.cardSize = L("offload_report_card_size")
        labels.copied = L("offload_report_copied")
        labels.started = L("offload_report_started")
        labels.finished = L("offload_report_finished")
        labels.elapsed = L("offload_report_elapsed")
        labels.average = L("offload_report_average")
        labels.manifest = L("offload_report_manifest")
        labels.manifestMissing = L("offload_report_manifest_missing")
        labels.writtenBy = L("offload_report_written_by")
        labels.writtenByFormat = L("offload_report_written_by_fmt")
        labels.filesVerifiedFormat = L("offload_report_files_verified_fmt")
        labels.explanation = L("offload_report_explanation")
        labels.destinationFailedHeading = L("offload_report_dest_failed")
        labels.mismatchesHeading = L("offload_report_mismatches")
        labels.sourceProblemsHeading = L("offload_report_source_problems")
        labels.scanProblemsHeading = L("offload_report_scan_problems")
        labels.verdictLabel = L("offload_report_verdict")
        labels.filesOfTotalFormat = L("offload_report_files_of_total_fmt")
        labels.verdictFailedFormat = L("offload_report_verdict_failed_fmt")
        labels.verdictMismatchFormat = L("offload_report_verdict_mismatch_fmt")
        labels.verdictCancelledFormat = L("offload_report_verdict_cancelled_fmt")
        labels.verdictIncompleteFormat = L("offload_report_verdict_incomplete_fmt")
        labels.verdictAllVerifiedFormat = L("offload_report_verdict_verified_fmt")
        labels.brand = L("offload_report_brand")
        labels.statFiles = L("offload_report_stat_files")
        labels.statCopied = L("offload_report_stat_copied")
        labels.statTime = L("offload_report_stat_time")
        labels.statSpeed = L("offload_report_stat_speed")
        labels.statFilesFormat = L("offload_report_stat_files_fmt")
        labels.problemsHeading = L("offload_report_problems")
        labels.footerFormat = L("offload_report_footer_fmt")
        labels.receiptMissing = L("offload_report_receipt_missing")
        labels.destinationFailedLineFormat = L("offload_report_dest_failed_fmt")
        labels.moreProblemsFormat = L("offload_report_more_problems_fmt")
        labels.hoursUnit = L("offload_report_hours_unit")
        labels.minutesUnit = L("offload_report_minutes_unit")
        labels.secondsUnit = L("offload_report_seconds_unit")
        return labels
    }
}
