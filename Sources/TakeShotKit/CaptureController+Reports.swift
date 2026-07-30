import AppKit
import CaptureCore
import Foundation

/// What leaves the shift as a document: the selects EDL and the shift report.
///
/// Split out of `+Markers`. Both are the same shape — build the file, put a
/// save panel in front of the operator, write it — and both are the end of the
/// day rather than part of running one.
extension CaptureController {
    /// Selects EDL: good takes back to back, markers as Resolve locators.
    func exportSelectsEDL() {
        let good = takes.filter { $0.rating == .good }
        guard let edl = EDLExporter.selectsEDL(
            takes: good, title: "\(settings.projectName) selects",
            fps: Int(max(1, playbackFPS).rounded()))
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
                try TakeLogExporter.reportCSV(takes: takes)
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            lastNotice = L("report_saved", url.lastPathComponent)
        } catch {
            lastError = "Report: \(error.localizedDescription)"
        }
    }
}
