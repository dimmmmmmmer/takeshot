import AppKit
import CaptureCore
import Foundation

/// What leaves the shift as a document: the selects EDL, the Avid log and the
/// shift report.
///
/// Split out of `+Markers`. All three are the same shape — build the file, put
/// a save panel in front of the operator, write it — and all three are the end
/// of the day rather than part of running one.
extension CaptureController {
    /// Selects EDL: good takes back to back, markers as Resolve locators, and
    /// the day's grade as `*ASC_SOP`/`*ASC_SAT` when the active look is an ASC
    /// CDL. `currentCDL` is nil for a .cube look, which is the point — the EDL
    /// carries nine numbers or nothing, never an invented identity.
    func exportSelectsEDL() {
        let good = takes.filter { $0.rating == .good }
        guard let edl = EDLExporter.selectsEDL(
            takes: good, title: "\(settings.projectName) selects",
            fps: Int(max(1, playbackFPS).rounded()), cdl: currentCDL)
        else {
            lastError = L("edl_no_good_takes")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_selects") + ".edl"
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try edl.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("edl_saved", url.lastPathComponent)
        } catch {
            lastError = "EDL: \(error.localizedDescription)"
        }
    }
    /// Avid log (ALE): every take, not just the selects.
    ///
    /// The EDL next to it is a cut and carries the circled takes only; this is
    /// the LOG, and an assistant building a bin needs the rejected takes in it
    /// too — that a take was marked bad is metadata about the day, not a reason
    /// to hide it from the Avid. `signalFormat` is the only source of a frame size,
    /// since a take carries timing but no raster; with no device attached the
    /// heading says CUSTOM rather than guessing.
    func exportALE() {
        guard let ale = ALEExporter.ale(takes: takes, format: signalFormat) else {
            lastError = L("ale_no_takes")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_log") + ".ale"
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ale.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("ale_saved", url.lastPathComponent)
        } catch {
            lastError = "ALE: \(error.localizedDescription)"
        }
    }
    /// Shift report: A4 PDF with thumbnails or a full CSV table.
    func exportShiftReport(pdf: Bool) {
        guard !takes.isEmpty else {
            lastError = L("report_no_takes")
            return
        }
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_report_\(stamp.string(from: Date()))")
            + (pdf ? ".pdf" : ".csv")
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                guard let data = ShiftReport.pdfData(
                    takes: takes, thumbnails: thumbnails,
                    project: settings.projectName,
                    camera: settings.cameraLabel) else {
                    lastError = "PDF render failed"
                    return
                }
                try data.write(to: url)
            } else {
                // labelled in the app language, like the PDF beside it — the
                // frozen Resolve sidecar is a different writer and stays as is
                try TakeLogExporter.reportCSV(takes: takes, labels: .current())
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            lastNotice = L("report_saved", url.lastPathComponent)
        } catch {
            lastError = "Report: \(error.localizedDescription)"
        }
    }
    /// Contact sheet: the day as an A4 thumbnail grid, one cell per take —
    /// the shift report's visual sibling (same header, same vocabulary).
    ///
    /// Posters are decoded here, per export, from the recorded files
    /// (`ContactSheet.exportThumbnails`) rather than taken from the panel's
    /// cache: the cache holds only what the grid scrolled past, and a sheet
    /// whose cells depend on scroll history is wrong. The decode is awaited,
    /// so the save panel closes first and the toast reports the finished file.
    func exportContactSheet() {
        guard !takes.isEmpty else {
            lastError = L("report_no_takes")
            return
        }
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = NamingEngine.sanitize(
            "\(settings.projectName)_contacts_\(stamp.string(from: Date()))")
            + ".pdf"
        panel.directoryURL = destinationRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let takes = takes
        let project = settings.projectName
        let camera = settings.cameraLabel
        Task { [weak self] in
            let posters = await ContactSheet.exportThumbnails(for: takes)
            guard let data = ContactSheet.pdfData(
                takes: takes, thumbnails: posters,
                project: project, camera: camera) else {
                self?.lastError = "PDF render failed"
                return
            }
            do {
                try data.write(to: url)
                self?.lastNotice = L("contact_saved", url.lastPathComponent)
            } catch {
                self?.lastError = "Report: \(error.localizedDescription)"
            }
        }
    }
}
