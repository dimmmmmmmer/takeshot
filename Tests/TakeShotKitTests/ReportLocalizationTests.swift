import CaptureCore
import Foundation
import PDFKit
import Testing

@testable import TakeShotKit

/// The reports leave the app in the language the app is set to (owner item 21):
/// the shift report — PDF and its CSV twin — and the offload's summary .txt and
/// report-card PNG. Each is generated here under the Russian UI and checked for
/// Russian labels; the injected-labels seam is also held to the CaptureCore
/// English defaults, so switching the language cannot change the English files.
///
/// What is pinned as NOT translated: the frozen Resolve sidecar
/// (`takeshot-log.csv`), whose schema machines read.
@MainActor
struct ReportLocalizationTests {
    private func take(_ index: Int, rating: TakeRating = .none) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/tmp/CLIP\(String(format: "%03d", index)).mov"),
            scene: "", roll: "001", takeNumber: index,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: index,
                                    frames: 0, fps: 25),
            durationSeconds: 12,
            recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = rating
        return take
    }

    // MARK: - the shift report

    @Test func theShiftReportPDFSpeaksTheAppLanguage() throws {
        let takes = [take(1, rating: .good), take(2, rating: .bad)]
        let data = try #require(ViewRender.withLanguage(.russian) {
            ShiftReport.pdfData(takes: takes, thumbnails: [:],
                                project: "Ночь", camera: "A")
        })
        let document = try #require(PDFDocument(data: data))
        let body = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        #expect(body.contains("отчёт смены"), "the title is not translated")
        #expect(body.contains("Камера A"))
        #expect(body.contains("2 дублей"))
        for column in ["КЛИП", "TC НАЧ", "TC КОН", "ДЛИТ", "ОЦЕНКА", "ЗАМЕТКИ"] {
            #expect(body.contains(column), "column \(column) is missing")
        }
        #expect(body.contains("ГОДЕН"))
        #expect(body.contains("БРАК"))
    }

    @Test func theShiftReportCSVSpeaksTheAppLanguage() {
        let csv = ViewRender.withLanguage(.russian) {
            TakeLogExporter.reportCSV(takes: [take(1, rating: .good)],
                                      labels: .current())
        }
        let lines = csv.components(separatedBy: "\n")
        #expect(lines[0] == "Имя файла,Ролл,Клип,Сцена,Кадр,Дубль,"
            + "TC начала,TC конца,Длительность,Оценка,Комментарии,Описание,"
            + "Маркеры,Записан")
        #expect(lines[1].contains("ГОДЕН"))
        // …and the English default is untouched by the labels seam existing
        #expect(TakeLogExporter.reportCSV(takes: []).hasPrefix("File Name,Roll,"))
    }

    /// The Resolve sidecar's schema is frozen and machine-read: the language
    /// switch must never reach it.
    @Test func theFrozenResolveSidecarIgnoresTheLanguage() {
        let csv = ViewRender.withLanguage(.russian) {
            TakeLogExporter.resolveCSV(takes: [take(1, rating: .good)])
        }
        #expect(csv.hasPrefix("File Name,Reel Name,Take,Good Take,Comments"))
    }

    // MARK: - the offload reports

    private func offloadRun() -> OffloadRunFacts {
        OffloadRunFacts(
            source: URL(fileURLWithPath: "/Volumes/CARD_A001"),
            algorithm: .xxh64,
            creator: OffloadCreatorInfo(toolName: "TakeShot",
                                        toolVersion: "0.1.0",
                                        hostname: "studio-mac.local"),
            span: OffloadSpan(
                started: Date(timeIntervalSince1970: 1_800_000_000),
                finished: Date(timeIntervalSince1970: 1_800_000_930)),
            card: OffloadVolume(files: 3, bytes: 4096))
    }

    private func offloadResult() -> OffloadDestinationResult {
        var result = OffloadDestinationResult(
            id: 0, url: URL(fileURLWithPath: "/Volumes/SSD1/CARD_A001"),
            totals: OffloadDestinationTotals(
                filesVerified: 3, filesTotal: 3, bytesWritten: 4096,
                elapsed: 930))
        result.manifestURL = URL(fileURLWithPath:
            "/Volumes/SSD1/CARD_A001/ascmhl/0001_CARD_A001.mhl")
        return result
    }

    /// The labels built under the English UI have to BE the CaptureCore
    /// defaults — that identity is what keeps the pinned byte-identical summary
    /// honest about what the app actually ships.
    @Test func theEnglishLabelsMatchTheCoreDefaults() {
        #expect(ViewRender.withLanguage(.english) {
            OffloadReportLabels.current()
        } == .english)
        #expect(ViewRender.withLanguage(.english) {
            ShiftReportCSVLabels.current()
        } == .english)
    }

    @Test func theOffloadSummarySpeaksTheAppLanguage() {
        let labels = ViewRender.withLanguage(.russian) {
            OffloadReportLabels.current()
        }
        let text = OffloadSummary.text(result: offloadResult(),
                                       run: offloadRun(), labels: labels)

        #expect(text.hasPrefix("TakeShot — проверенный офлоуд\n"))
        for label in ["Источник:", "Назначение:", "Затрачено:",
                      "15 мин 30 с", "ВЕРДИКТ:", "все файлы проверены: 3"] {
            #expect(text.contains(label), "missing in the summary: \(label)")
        }
        #expect(!text.contains("VERDICT"))
    }

    /// The PNG cannot be grepped for words, so what is held is that Russian
    /// labels render a decodable card at all (CoreText + Cyrillic through the
    /// same path), and that the words the canvas draws come from the labels.
    @Test func theOffloadReportCardRendersWithRussianLabels() throws {
        let labels = ViewRender.withLanguage(.russian) {
            OffloadReportLabels.current()
        }
        #expect(labels.brand == "TAKESHOT — ПРОВЕРЕННЫЙ ОФЛОУД")
        let data = try #require(OffloadReportCard.png(
            result: offloadResult(), run: offloadRun(), labels: labels))
        #expect(data.count > 1000)
        // the capped problem line's words follow the language too (that the
        // cap USES the injected line is pinned in OffloadReportCardTests,
        // where the internal seam is reachable)
        #expect(labels.moreProblemsFormat == "…и ещё %d — см. сводку .txt")
    }

    /// End to end through the engine: a plan stamped with Russian labels leaves
    /// a Russian summary on the destination disk. This is the seam the app
    /// actually uses — `OffloadSheetModel.start()` stamps `.current()` into the
    /// plan the same way.
    @Test func theEngineWritesTheSummaryInThePlansLanguage() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-report-l10n-\(UUID().uuidString)")
        let card = scratch.appendingPathComponent("card")
        let disk = scratch.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: card,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("clip".utf8).write(to: card.appendingPathComponent("A001.mov"))

        let labels = ViewRender.withLanguage(.russian) {
            OffloadReportLabels.current()
        }
        let report = OffloadEngine.run(OffloadPlan(
            source: card, destinations: [disk], reportLabels: labels))

        let summaryURL = try #require(report.destinations.first?.summaryURL)
        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        #expect(summary.contains("ВЕРДИКТ: все файлы проверены: 1"))
        #expect(summary.contains("Манифест:"))
        // the card PNG beside it was written with the same labels
        #expect(report.destinations.first?.imageURL != nil)
    }
}
