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
        guard let edl = EDLExporter.selectsEDL(
            takes: goodTakes, title: "\(settings.naming.projectName) selects",
            fps: Int(max(1, playbackFPS).rounded()), cdl: currentCDL)
        else {
            lastError = L("export_no_good_takes")
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
    /// Avid log (ALE): the circled takes, like every other item in that menu.
    ///
    /// **It used to carry every take that was shot**, on the argument that an
    /// assistant building a bin wants the rejected ones too — that a take was
    /// marked bad is metadata about the day rather than grounds for hiding it
    /// from the Avid. The owner overruled it for all three timeline formats
    /// ("экспорт тейков – каждый должен экспортить только хорошие; таймлайн со
    /// всеми мне зачем? просто на хорошие чтоб разные форматы таймлайна
    /// были"), and the argument survives where it belongs: the SHIFT REPORT is
    /// the document of the whole day, lists every take good or bad, and is in
    /// the menu next door. The timeline menu is three spellings of one cut.
    ///
    /// `signalFormat` is the only source of a frame size, since a take carries
    /// timing but no raster; with no device attached the heading says CUSTOM
    /// rather than guessing.
    func exportALE() {
        // `currentCDL` is nil for a .cube look, exactly as the EDL above reads
        // it — nine invented numbers in a machine-read column are worse than a
        // column that is not there.
        guard let ale = ALEExporter.ale(takes: goodTakes, format: signalFormat,
                                        cdl: currentCDL)
        else {
            lastError = L("export_no_good_takes")
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
    /// The circled takes, for the ALE's reason — see there.
    func exportFCPXML() {
        guard let xml = FCPXMLExporter.timeline(
            takes: goodTakes, project: settings.naming.projectName,
            format: signalFormat) else {
            lastError = L("export_no_good_takes")
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

    /// **FCP7 XML timeline** (owner: "таймлайн хмл мне нужен .xml а не
    /// fcpxml"): the same cut as the FCPXML beside it, in the `xmeml` every
    /// edit suite reads rather than the one two applications read.
    ///
    /// Both are offered and neither replaces the other — see
    /// `FCP7XMLExporter`'s own note for what actually differs between the two
    /// documents. The circled takes, for the ALE's reason.
    func exportFCP7XML() {
        guard let xml = FCP7XMLExporter.timeline(
            takes: goodTakes, project: settings.naming.projectName,
            format: signalFormat) else {
            lastError = L("export_no_good_takes")
            return
        }
        let name = NamingEngine.sanitize(
            "\(settings.naming.projectName)_timeline") + ".xml"
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
            try TakeLogExporter.reportCSV(reportMaterial, labels: .current())
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

    /// **The day's takes together with the in/out marks filed against them.**
    ///
    /// The marks live on the transport, keyed by file name, and the report
    /// writers want both — so the pairing is made ONCE, here, where the two
    /// halves are known to belong to the same session. `storedRanges` rather
    /// than the table alone: the clip in the player has not been filed yet,
    /// and a report exported with a take still loaded would otherwise quote a
    /// runtime that ignores the mark the operator just made.
    var reportMaterial: TakeRuntime.ReportMaterial {
        TakeRuntime.ReportMaterial(takes, ranges: transport.storedRanges)
    }

    /// The PDF half: fill in the pictures the panel never loaded, then render.
    private func writeShiftReportPDF(to url: URL) -> Task<Void, Never> {
        let material = reportMaterial
        let takes = takes
        let cached = thumbnails
        let project = settings.naming.projectName
        let camera = settings.naming.cameraLabel
        let missing = Self.takesNeedingPosters(takes, cached: cached)
        return Task { [weak self] in
            var pictures = cached
            for (id, image) in await TakePosters.exportThumbnails(for: missing) {
                pictures[id] = image
            }
            guard let data = ShiftReport.pdfData(
                material, thumbnails: pictures,
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

}
