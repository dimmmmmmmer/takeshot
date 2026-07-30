import Foundation
import Testing

@testable import TakeShotKit

/// The operator guide is a Markdown resource per language rather than a wall of
/// L() keys, which buys two failure modes a .strings file does not have: the
/// resource can miss the bundle entirely (a blank help window), and the two
/// languages can drift apart section by section with nothing complaining. Both
/// are pinned here, along with the small parser that turns the file into blocks.
@MainActor
struct ModelHelpDocumentTests {
    private func document(_ language: AppLanguage) -> HelpDocument {
        ViewRender.withLanguage(language) { HelpDocument.current() }
    }

    /// A missing resource is the difference between a manual and an empty
    /// window, and the language switch has to move the document with it.
    @Test func theGuideLoadsInBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            let guide = document(language)
            #expect(!guide.blocks.isEmpty,
                    "\(language.rawValue): Help.md did not resolve in the bundle")
            #expect(!guide.title.isEmpty, "\(language.rawValue): no title line")
            #expect(guide.sections.count >= 8,
                    "\(language.rawValue): only \(guide.sections.count) sections")
        }
    }

    /// Which file each bundle returned, not merely that they differ — swap the
    /// two Help.md files and "they differ" still holds. `HelpDocument` reads the
    /// bundle `L10n` is holding rather than `Bundle.module` precisely so that the
    /// in-app language switch moves the guide with it; read from `.module` the
    /// answer would be the SYSTEM language's file for both.
    @Test func eachLanguageBundleReturnsItsOwnFile() {
        func hasCyrillic(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }
        #expect(hasCyrillic(document(.russian).title),
                "the ru bundle did not return the Russian Help.md")
        #expect(!hasCyrillic(document(.english).title),
                "the en bundle returned the Russian Help.md")
    }

    @Test func theTwoGuidesAreDifferentTextAndTheSameShape() {
        let en = document(.english)
        let ru = document(.russian)
        #expect(en.title != ru.title, "the Russian guide is the English one")
        // A section or a bullet list that never got translated shows up as a
        // count that no longer matches — the same check the .strings files get.
        #expect(en.sections.count == ru.sections.count,
                "sections: \(en.sections.count) en vs \(ru.sections.count) ru")
        let enBullets = en.blocks.filter { $0.kind == .bullet }.count
        let ruBullets = ru.blocks.filter { $0.kind == .bullet }.count
        #expect(enBullets == ruBullets,
                "bullets: \(enBullets) en vs \(ruBullets) ru")
    }

    /// Markdown that reached the screen unparsed is the visible failure: a
    /// heading rendered as "## Exports", a bullet as "- text".
    @Test func noMarkupSurvivesIntoTheRenderedBlocks() {
        for language in [AppLanguage.english, .russian] {
            for block in document(language).blocks {
                #expect(!block.text.hasPrefix("#"),
                        "\(language.rawValue): unparsed heading \(block.text)")
                #expect(!block.text.hasPrefix("- "),
                        "\(language.rawValue): unparsed bullet \(block.text)")
            }
        }
    }

    /// The file is wrapped at 80 columns for whoever edits it; rendering those
    /// breaks would put a ragged edge down the middle of the window.
    @Test func wrappedSourceLinesBecomeOneBlock() {
        let parsed = HelpDocument.parse("""
            # Title

            A paragraph that the author
            wrapped across three
            source lines.

            ## Section

            - a bullet
              continued underneath
            - a second bullet
            """)
        #expect(parsed.title == "Title")
        #expect(parsed.blocks.map(\.kind)
                == [.title, .paragraph, .section, .bullet, .bullet])
        #expect(parsed.blocks[1].text
                == "A paragraph that the author wrapped across three source lines.")
        #expect(parsed.blocks[3].text == "a bullet continued underneath")
        #expect(parsed.blocks[4].text == "a second bullet")
    }

    /// A blank document is a build problem, not a crash: the view says so.
    @Test func anEmptyDocumentHasNoBlocks() {
        let parsed = HelpDocument.parse("")
        #expect(parsed.blocks.isEmpty)
        #expect(parsed.title.isEmpty)
    }
}
