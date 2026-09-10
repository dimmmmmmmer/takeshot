import SwiftUI
import Testing

@testable import TakeShotKit

/// **The folder button does not set the header's height.**
///
/// Both section headers carry one, and both had it as a 14pt glyph in a
/// `.small` bordered button — taller than the header's own title, so the
/// button decided the row's height and its border ran into the panel's plate
/// above and below it (owner: "кнопки открытия папки целевой сделай поменьше –
/// они задевают края своего блока по подложке сверху и снизу").
///
/// Measured against the TITLE rather than against a number: the air the owner
/// is missing is the difference between the row's height and the plate's
/// padding, and the row is as tall as its tallest child. A button no taller
/// than the words beside it cannot be that child.
@Suite @MainActor struct ViewPanelFolderButtonTests {
    /// The title the takes header draws, spelled exactly as `TakesSection`
    /// spells it — this is the thing the button must not out-grow.
    private func title() -> some View {
        Text(L("takes"))
            .font(.subheadline.weight(.semibold))
            .fixedSize()
    }

    @Test func theFolderButtonDoesNotSetTheHeaderHeight() async throws {
        try await ViewProbe.run { probe in
            let button = probe.fittingSizes { PanelFolderButton {} }
            let words = probe.fittingSizes { self.title() }

            #expect(button.en == button.ru,
                    "the folder button is language-dependent: \(button)")
            #expect(button.en.height <= words.ru.height, """
                the folder button is \(button.en.height)pt against a \
                \(words.ru.height)pt title — it sets the header's height, and \
                its border lands on the panel's plate
                """)
            // …and it is still a real, pressable control rather than a glyph
            // squeezed to nothing: a 12pt box inside a mini bordered button.
            #expect(button.en.width >= PanelChrome.folderButtonSide,
                    "the folder button collapsed to \(button.en.width)pt")
        }
    }

    /// **One definition, mounted twice.** The two headers each had their own
    /// copy of the button, and a copy is what let them drift — this asserts
    /// they now go through the one view.
    @Test func bothSectionHeadersMountTheSharedButton() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        for name in ["TakeListView", "OtherContentSection"] {
            let code = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains("PanelFolderButton {"),
                    "\(name) does not mount the shared folder button")
            #expect(!code.contains("Image(systemName: \"folder\")"),
                    "\(name) still builds a folder button of its own")
        }
    }
}
