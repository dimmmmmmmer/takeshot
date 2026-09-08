import AppKit
import CaptureCore
import Foundation

/// What leaves the shift as a document: the selects EDL, the Avid log and the
/// shift report.
///
/// Split out of `+Markers`. All three are the same shape — build the file, put
/// a save panel in front of the operator, write it — and all three are the end
/// of the day rather than part of running one.
///
/// The panel itself is `FilePanel`, not `NSSavePanel`: see the note there for
/// why the dialog is a seam. Everything below the panel — the offered name, the
/// offered folder, the bytes, and what the operator is told when the write fails
/// — is then reachable from a test.
extension CaptureController {
    /// The date stamp both A4 documents put in their file name. `en_US_POSIX`
    /// so the digits are the same in every locale the app runs in — a report
    /// named in Hindi numerals sorts nowhere.
    static func reportDateStamp(_ date: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyMMdd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return stamp.string(from: date)
    }

    /// Selects EDL: good takes back to back, markers as Resolve locators, and
    /// the day's grade as `*ASC_SOP`/`*ASC_SAT` when the active look is an ASC
    /// CDL. `currentCDL` is nil for a .cube look, which is the point — the EDL
    /// carries nine numbers or nothing, never an invented identity.
    func exportSelectsEDL() {
        let good = takes.filter { $0.rating == .good }
        guard let edl = EDLExporter.selectsEDL(
            takes: good, title: "\(settings.naming.projectName) selects",
            fps: Int(max(1, playbackFPS).rounded()), cdl: currentCDL)
        else {
            lastError = L("edl_no_good_takes")
            return
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_selects") + ".edl"
        guard let url = FilePanel.save(named: name, in: destinationRoot)
        else { return }
        do {
            try edl.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("edl_saved", url.lastPathComponent)
        } catch {
            lastError = L("toast_edl_failed", error.localizedDescription)
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
        let name = NamingEngine.sanitize("\(settings.naming.projectName)_log") + ".ale"
        guard let url = FilePanel.save(named: name, in: destinationRoot)
        else { return }
        do {
            try ale.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("ale_saved", url.lastPathComponent)
        } catch {
            lastError = L("toast_ale_failed", error.localizedDescription)
        }
    }
    /// FCPXML timeline: every take, back to back, each clip pointing at its
    /// own file.
    ///
    /// The third of the three and the only one that carries the MEDIA. The EDL
    /// beside it is a cut list of reels and the ALE is a log; both leave the
    /// assistant to relink, which on a video-assist day means relinking against
    /// names that were never on a camera original. This opens with the picture
    /// already on the timeline, in Resolve and in Premiere alike.
    ///
    /// Every take rather than the selects, for the ALE's reason: this is the
    /// day, and a take marked bad is metadata about it rather than grounds for
    /// leaving it out of the assistant's bin.
    func exportFCPXML() {
        guard let xml = FCPXMLExporter.timeline(
            takes: takes, project: settings.naming.projectName,
            format: signalFormat) else {
            lastError = L("fcpxml_no_takes")
            return
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_timeline") + ".fcpxml"
        guard let url = FilePanel.save(named: name, in: destinationRoot)
        else { return }
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("fcpxml_saved", url.lastPathComponent)
        } catch {
            lastError = L("toast_fcpxml_failed", error.localizedDescription)
        }
    }

    /// Shift report: A4 PDF with thumbnails or a full CSV table.
    ///
    /// The PDF's pictures come from the panel's cache where it has them and are
    /// DECODED where it does not. The cache holds only what the grid scrolled
    /// past, so a report written after a long day carried blank cells for every
    /// take the operator never scrolled to — silently, with no gap in the table
    /// to notice it by. That is the contact sheet's own stated rule ("a sheet
    /// whose cells depend on scroll history is wrong") applied to the document
    /// beside it, which had it backwards.
    ///
    /// The Task is handed back for the contact sheet's reason: a test can await
    /// the decode instead of polling for a file. The app ignores it, and the
    /// CSV — which has no pictures — returns nil and is finished when it
    /// returns.
    @discardableResult
    func exportShiftReport(pdf: Bool) -> Task<Void, Never>? {
        guard !takes.isEmpty else {
            lastError = L("report_no_takes")
            return nil
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_report_\(Self.reportDateStamp())")
            + (pdf ? ".pdf" : ".csv")
        guard let url = FilePanel.save(named: name, in: destinationRoot)
        else { return nil }
        if pdf { return writeShiftReportPDF(to: url) }
        do {
            // labelled in the app language, like the PDF beside it — the
            // frozen Resolve sidecar is a different writer and stays as is
            try TakeLogExporter.reportCSV(takes: takes, labels: .current())
                .write(to: url, atomically: true, encoding: .utf8)
            lastNotice = L("report_saved", url.lastPathComponent)
        } catch {
            lastError = L("toast_report_failed", error.localizedDescription)
        }
        return nil
    }

    /// **Which takes the panel never loaded a picture for.**
    ///
    /// Its own function because it is the whole of the fix: the report used to
    /// pass the cache through as it stood, and a take the operator never
    /// scrolled to came out as a blank cell. Only the missing ones, so a day
    /// that has been scrolled through decodes nothing at all.
    static func takesNeedingPosters(_ takes: [Take],
                                    cached: [UUID: NSImage]) -> [Take] {
        takes.filter { cached[$0.id] == nil }
    }

    /// The PDF half: fill in the pictures the panel never loaded, then render.
    private func writeShiftReportPDF(to url: URL) -> Task<Void, Never> {
        let takes = takes
        let cached = thumbnails
        let project = settings.naming.projectName
        let camera = settings.naming.cameraLabel
        let missing = Self.takesNeedingPosters(takes, cached: cached)
        return Task { [weak self] in
            var pictures = cached
            for (id, image) in await ContactSheet.exportThumbnails(for: missing) {
                pictures[id] = image
            }
            guard let data = ShiftReport.pdfData(
                takes: takes, thumbnails: pictures,
                project: project, camera: camera) else {
                self?.lastError = L("toast_pdf_render_failed")
                return
            }
            do {
                try data.write(to: url)
                self?.lastNotice = L("report_saved", url.lastPathComponent)
            } catch {
                self?.lastError = L("toast_report_failed",
                                    error.localizedDescription)
            }
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
    @discardableResult
    func exportContactSheet() -> Task<Void, Never>? {
        guard !takes.isEmpty else {
            lastError = L("report_no_takes")
            return nil
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_contacts_\(Self.reportDateStamp())")
            + ".pdf"
        guard let url = FilePanel.save(named: name, in: destinationRoot)
        else { return nil }
        let takes = takes
        let project = settings.naming.projectName
        let camera = settings.naming.cameraLabel
        // Handed back so a test can await the decode instead of polling for a
        // file that a background decode has not written yet. The app ignores it.
        return Task { [weak self] in
            let posters = await ContactSheet.exportThumbnails(for: takes)
            guard let data = ContactSheet.pdfData(
                takes: takes, thumbnails: posters,
                project: project, camera: camera) else {
                self?.lastError = L("toast_pdf_render_failed")
                return
            }
            do {
                try data.write(to: url)
                self?.lastNotice = L("contact_saved", url.lastPathComponent)
            } catch {
                self?.lastError = L("toast_report_failed", error.localizedDescription)
            }
        }
    }
}
