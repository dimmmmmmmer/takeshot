import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The four documents that leave the shift: the selects EDL, the Avid log, the
/// shift report and the contact sheet.
///
/// The save panel is `FilePanel`, so these run all the way through — the panel
/// is answered with a scratch URL instead of stopping the suite on
/// `NSSavePanel.runModal()`. What that buys is the half that actually matters at
/// the end of a day: the name each document is offered under, the folder it is
/// offered in, what the bytes turn out to be, and what the operator is told when
/// the disk says no. `ControllerReportGuardTests` covers the refusals in front of
/// all of this.
@Suite @MainActor struct ControllerExportDocumentTests {
    /// A harness run with the project named. Every one of these documents takes
    /// its file name from `projectName`, so most of them need it set.
    private func project(
        _ name: String,
        _ body: (CaptureController, URL) async throws -> Void) async throws {
        try await ControllerHarness.run(configure: { $0.projectName = name }, body)
    }

    /// A day with one circled take and one rejected one. Both are backed by a
    /// file, so a folder rescan cannot retire them mid-test.
    private func day(_ controller: CaptureController,
                     in root: URL) throws -> (good: Take, bad: Take) {
        var good = ControllerFixtures.take(named: "A001C001", in: root, clip: 1)
        good.rating = .good
        var bad = ControllerFixtures.take(named: "A001C002", in: root, clip: 2)
        bad.rating = .bad
        try ControllerFixtures.placeholder(for: good)
        try ControllerFixtures.placeholder(for: bad)
        controller.takes = [good, bad]
        return (good, bad)
    }

    /// The selects EDL is the circled takes and nothing else, and the operator
    /// is told what was written.
    @Test func theEDLCarriesTheCircledTakesAndReportsTheFile() async throws {
        try await project("Nightshoot") { controller, root in
            let day = try self.day(controller, in: root)
            let destination = root.appendingPathComponent("out.edl")

            try await FakeFilePanel.installed(saving: [destination]) { panel in
                controller.exportSelectsEDL()

                #expect(panel.lastSaveName == "Nightshoot_selects.edl")
                #expect(panel.lastSaveDirectory == root,
                        "the EDL was offered somewhere other than the record folder")
                let text = try String(contentsOf: destination, encoding: .utf8)
                #expect(text.contains("TITLE: Nightshoot selects"))
                #expect(text.contains(day.good.url.lastPathComponent))
                #expect(!text.contains(day.bad.url.lastPathComponent),
                        "a rejected take made it into the selects cut")
                #expect(controller.lastNotice == L("edl_saved", "out.edl"))
                #expect(controller.lastError == nil)
            }
        }
    }

    /// Cancel writes nothing and says nothing. A cancelled export is a decision,
    /// not a failure — an error toast for it would train the operator to ignore
    /// the toasts that matter.
    @Test func cancellingAnExportIsSilent() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try self.day(controller, in: root)

            controller.lastNotice = nil
            controller.lastError = nil

            try await FakeFilePanel.installed { panel in
                controller.exportSelectsEDL()
                controller.exportALE()
                controller.exportShiftReport(pdf: false)
                #expect(controller.exportContactSheet() == nil,
                        "a cancelled contact sheet started decoding anyway")

                #expect(panel.saveRequests.count == 4,
                        "an export never got as far as the panel")
                #expect(controller.lastNotice == nil)
                #expect(controller.lastError == nil)
                let written = try FileManager.default.contentsOfDirectory(
                    atPath: root.path)
                    .filter { $0.hasSuffix(".edl") || $0.hasSuffix(".ale")
                        || $0.hasSuffix(".csv") || $0.hasSuffix(".pdf") }
                #expect(written.isEmpty, "a cancelled export wrote \(written)")
            }
        }
    }

    /// A write that fails is reported with the exporter's name in front of it.
    /// The operator has to know which document did not make it — silence here
    /// means a day's paperwork is missing and nobody finds out until the morning.
    @Test func aWriteThatFailsIsReportedPerDocument() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try self.day(controller, in: root)
            // a folder that is not there: the write throws rather than the panel
            let dead = root.appendingPathComponent("gone/report")

            try await FakeFilePanel.installed(
                saving: [dead.appendingPathExtension("edl"),
                         dead.appendingPathExtension("ale"),
                         dead.appendingPathExtension("csv")]) { _ in
                controller.exportSelectsEDL()
                #expect(controller.lastError?.hasPrefix("EDL: ") == true,
                        "EDL failure said: \(controller.lastError ?? "nothing")")

                controller.exportALE()
                #expect(controller.lastError?.hasPrefix("ALE: ") == true,
                        "ALE failure said: \(controller.lastError ?? "nothing")")

                controller.exportShiftReport(pdf: false)
                #expect(controller.lastError?.hasPrefix("Report: ") == true,
                        "report failure said: \(controller.lastError ?? "nothing")")
            }
        }
    }

    /// The ALE is the LOG: every take, including the rejected ones. The EDL
    /// beside it is the cut and carries the circled takes only.
    @Test func theALECarriesEveryTake() async throws {
        try await project("Nightshoot") { controller, root in
            let day = try self.day(controller, in: root)
            let destination = root.appendingPathComponent("log.ale")

            try await FakeFilePanel.installed(saving: [destination]) { panel in
                controller.exportALE()

                #expect(panel.lastSaveName == "Nightshoot_log.ale")
                let text = try String(contentsOf: destination, encoding: .utf8)
                #expect(text.contains("FIELD_DELIM\tTABS"))
                #expect(text.contains(day.good.url.lastPathComponent))
                #expect(text.contains(day.bad.url.lastPathComponent),
                        "the Avid log hid the rejected take")
                #expect(controller.lastNotice == L("ale_saved", "log.ale"))
            }
        }
    }

    /// The CSV report is a table with the app's own column headings — the
    /// localized report, not the frozen Resolve sidecar next to the footage.
    @Test func theCSVReportIsATableInTheAppsOwnLanguage() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try self.day(controller, in: root)
            let destination = root.appendingPathComponent("report.csv")

            try await FakeFilePanel.installed(saving: [destination]) { _ in
                controller.exportShiftReport(pdf: false)

                let text = try String(contentsOf: destination, encoding: .utf8)
                let lines = text.split(separator: "\n")
                #expect(lines.first?.contains(L("report_csv_file")) == true,
                        "the CSV heading read \(lines.first ?? "nothing")")
                // heading plus one row per take
                #expect(lines.count == 3)
                #expect(controller.lastNotice == L("report_saved", "report.csv"))
            }
        }
    }

    /// The PDF report is a real PDF, not an empty file with the extension on it.
    @Test func thePDFReportIsARealPDF() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try self.day(controller, in: root)
            let destination = root.appendingPathComponent("report.pdf")

            try await FakeFilePanel.installed(saving: [destination]) { _ in
                controller.exportShiftReport(pdf: true)

                let data = try Data(contentsOf: destination)
                #expect(data.starts(with: Array("%PDF".utf8)),
                        "the report is \(data.count) bytes and not a PDF")
                #expect(controller.lastNotice == L("report_saved", "report.pdf"))
            }
        }
    }

    /// The contact sheet decodes its own posters and only then reports the file,
    /// so the toast never names a document that is still being written.
    @Test func theContactSheetIsWrittenBeforeItIsAnnounced() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try self.day(controller, in: root)
            let destination = root.appendingPathComponent("contacts.pdf")

            try await FakeFilePanel.installed(saving: [destination]) { panel in
                let export = controller.exportContactSheet()
                #expect(panel.lastSaveName?.hasSuffix(".pdf") == true)
                await export?.value

                let data = try Data(contentsOf: destination)
                #expect(data.starts(with: Array("%PDF".utf8)))
                #expect(controller.lastNotice == L("contact_saved", "contacts.pdf"))
            }
        }
    }

    /// Both A4 documents are named with a date stamp, and it is numeric in every
    /// language the app runs in: a file whose digits change shape with the UI
    /// language does not sort next to yesterday's.
    @Test func theA4DocumentsCarryANumericDateStamp() async throws {
        // Checked against the calendar rather than against a literal: the same
        // instant is a different day in a different zone, and a literal here
        // would be a fact about the machine that wrote it. What is pinned is the
        // SHAPE — six ASCII digits, yyMMdd — which is what makes two days'
        // reports sort next to each other whatever the UI language is.
        let reference = Date(timeIntervalSince1970: 1_772_000_000)
        let stamp = CaptureController.reportDateStamp(reference)
        let parts = Calendar.current.dateComponents([.year, .month, .day],
                                                    from: reference)
        let expected = String(format: "%02d%02d%02d",
                              try #require(parts.year) % 100,
                              try #require(parts.month),
                              try #require(parts.day))
        #expect(stamp == expected, "the stamp read \(stamp), expected \(expected)")
        #expect(stamp.allSatisfy { $0.isASCII && $0.isNumber })

        try await project("Show") { controller, root in
            _ = try self.day(controller, in: root)
            let today = CaptureController.reportDateStamp()

            try await FakeFilePanel.installed(
                saving: [root.appendingPathComponent("r.csv"),
                         root.appendingPathComponent("c.pdf")]) { panel in
                controller.exportShiftReport(pdf: false)
                #expect(panel.lastSaveName == "Show_report_\(today).csv")
                // awaited so the decode cannot outlive the scratch folder
                await controller.exportContactSheet()?.value
                #expect(panel.lastSaveName == "Show_contacts_\(today).pdf")
            }
        }
    }

    /// A project name with a path separator in it cannot become a path. The
    /// operator types this field, and "Show 1/2" reaching the panel as a
    /// directory component is how an export lands somewhere nobody looks.
    @Test func aProjectNameIsSanitizedBeforeItBecomesAFileName() async throws {
        try await project("Big/Show: 2026") { controller, root in
            _ = try self.day(controller, in: root)

            try await FakeFilePanel.installed(
                saving: [root.appendingPathComponent("out.ale")]) { panel in
                controller.exportALE()
                let offered = try #require(panel.lastSaveName)
                #expect(!offered.contains("/"), "the panel was offered \(offered)")
                #expect(!offered.contains(":"), "the panel was offered \(offered)")
                #expect(offered.hasSuffix("_log.ale"))
            }
        }
    }
}
