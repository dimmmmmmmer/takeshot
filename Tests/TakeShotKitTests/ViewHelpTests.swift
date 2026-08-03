import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// The help window is the only view in the app that is mostly prose, which makes
/// it the one place a translation can quietly force the window wider: a long
/// unbreakable token (`takeshot-markers.csv`, `TAKESHOT_DEMO=1`) does not wrap,
/// and neither does a Russian compound. What is measured here is that the guide
/// still fits the width the window gives it, in both languages, and that it
/// renders at all — a help page that throws its content away is indistinguishable
/// from a blank one until someone opens it.
@MainActor
struct ViewHelpTests {
    @Test func theGuideFitsTheHelpWindowInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let narrowest = probe.minimumWidths {
                HelpBody(document: HelpDocument.current())
            }
            #expect(narrowest.en <= HelpView.contentWidth,
                    "the English guide cannot compress below \(narrowest.en)pt")
            #expect(narrowest.ru <= HelpView.contentWidth,
                    "the Russian guide cannot compress below \(narrowest.ru)pt")
        }
    }

    /// Rendered at the window's own width the guide has to be several screens
    /// tall in both languages — a document that failed to load measures as one
    /// line of "help unavailable".
    @Test func theGuideRendersInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let rendered = probe.sizes(proposedWidth: HelpView.contentWidth) {
                HelpBody(document: HelpDocument.current())
            }
            #expect(rendered.en.height > 1000,
                    "the English guide rendered \(rendered.en.height)pt tall")
            #expect(rendered.ru.height > 1000,
                    "the Russian guide rendered \(rendered.ru.height)pt tall")
        }
    }

    /// The window itself, with the scroll view and the padding around it: it must
    /// accept the minimum size the scene declares without its content demanding
    /// more.
    @Test func theHelpWindowLaysOutAtItsMinimumSize() async throws {
        try await ViewProbe.run { probe in
            let minimum = CGSize(width: 420, height: 320)
            let laidOut = ViewRender.laidOutSize(probe.hosted(HelpView()),
                                                 in: minimum)
            #expect(laidOut == minimum, "the help window stretched to \(laidOut)")
        }
    }

    /// An empty document is a build problem — the view has to say so rather than
    /// show a blank page.
    ///
    /// Measured against the explanation line itself, not against zero: the body
    /// of an empty document IS that one line, so dropping the branch (a blank
    /// page) and swapping the string for a different one both move the answer.
    /// The "taller and wider than nothing" assertion this replaces passed
    /// against either.
    @Test func aMissingGuideRendersAnExplanation() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                HelpBody(document: HelpDocument.parse(""))
            }
            let line = probe.fittingSizes {
                Text(L("help_unavailable")).foregroundStyle(.secondary)
            }
            #expect(ideal.en.matches(line.en, slack: 1),
                    "English: \(ideal.en) for a line that measures \(line.en)")
            #expect(ideal.ru.matches(line.ru, slack: 1),
                    "Russian: \(ideal.ru) for a line that measures \(line.ru)")
        }
    }
}
