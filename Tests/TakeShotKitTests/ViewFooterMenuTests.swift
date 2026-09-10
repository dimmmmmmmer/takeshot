import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **Two menus in one bar wear one disclosure.**
///
/// The codec menu hid the system indicator and drew a 7pt chevron by hand;
/// the naming menu beside it showed the real one. Measured, that was 24pt
/// against 38 — and at 7pt the mark reads as nothing, so the codec looked
/// like a readout and its neighbour like a menu (owner: "у кнопки кодека нет
/// рядом с иконкой стрелочки вниз как у иконки наименований").
///
/// Measured rather than grepped: what went wrong was how BIG the mark was,
/// and a source rule saying "draws a chevron" was satisfied the whole time.
@Suite @MainActor struct ViewFooterMenuTests {
    @Test func theCodecMenuLooksAsMuchLikeAMenuAsTheOneBesideIt() async throws {
        try await ViewProbe.run { probe in
            let codec = probe.fittingSizes { probe.hosted(FooterCodecMenu()) }
            let naming = probe.fittingSizes { probe.hosted(NamingPresetMenu()) }
            #expect(abs(codec.en.width - naming.en.width) <= 4,
                    "codec \(codec.en.width)pt vs naming \(naming.en.width)pt")
            #expect(abs(codec.ru.width - naming.ru.width) <= 4,
                    "codec \(codec.ru.width)pt vs naming \(naming.ru.width)pt")
            // …and both really DRAW a mark beside the glyph. Measured as ink
            // rather than as width: a `Menu`'s reported size is the control's,
            // not its label's, so a width is a proxy — and the old rule was an
            // absolute 30pt, a proxy that read as a failure the moment the
            // mark stopped being AppKit's own.
            for (name, view) in [("codec", AnyView(FooterCodecMenu())),
                                 ("naming", AnyView(NamingPresetMenu()))] {
                let runs = Self.inkRuns(probe, view)
                #expect(runs >= 2, Comment(rawValue: """
                    the \(name) menu draws \(runs) shape(s) — a glyph with no \
                    mark beside it
                    """))
            }
        }
    }

    /// How many separate shapes a control draws across its width — a glyph and
    /// a mark beside it are two.
    static func inkRuns(_ probe: ViewProbe, _ view: AnyView) -> Int {
        let columns = probe.brightColumns(view, in: CGSize(width: 90, height: 40))
        var runs = 0
        var previous = -2
        for column in columns {
            if column != previous + 1 { runs += 1 }
            previous = column
        }
        return runs
    }

    /// **All three marks are one mark, and it points up.**
    ///
    /// The two menus took AppKit's own indicator, pointing DOWN, while the
    /// volume popover beside them drew its own pointing UP — three controls in
    /// one row that open something, wearing two different marks (owner:
    /// "стрелочка вверх у звука отличается от стрелочек вниз у соседних
    /// иконок; давай у всех стрелочки вверх сделаем и пусть они будут
    /// одинаковые"). Asserted on the source: what is wrong with two marks is
    /// that they are two, and a render can only measure one at a time.
    @Test func everyFooterControlThatOpensSomethingWearsTheSameMark() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        var marks = 0
        for name in ["FooterBar", "FooterFormatControls"] {
            let code = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // Two shapes for one mark: a `Menu` bakes it into its image and the
            // popover button draws it as a view — see `FooterMarkedSymbol` for
            // why the menus cannot simply compose a label.
            marks += code.components(separatedBy: "FooterDisclosure()").count - 1
            marks += code.components(
                separatedBy: "FooterMarkedSymbol.image(").count - 1
            #expect(!code.contains("systemName: \"chevron"),
                    "\(name) draws a chevron of its own again")
        }
        // the codec menu, the naming menu and the volume popover
        #expect(marks == 3, "\(marks) controls wear the shared mark, not three")
        // …and the mark itself is stated in exactly one place, pointing up
        #expect(FooterMarkedSymbol.mark == "chevron.up")
    }
}
