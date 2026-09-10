import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The slate page's face**, asserted on the served markup.
///
/// Three reports in one round: the roll was a caption rather than a cell, the
/// state tags were words nobody could decode, and the face was light when the
/// owner wants it dark ("давай хлопушка не с белым фоном будет а с черным и
/// буквы белые").
@Suite @MainActor struct SlateFaceTests {
    private var html: String {
        String(bytes: RemotePage.slateHTML(), encoding: .utf8) ?? ""
    }

    /// **Dark face, light letters.** Committing to one look is the point — a
    /// slate that is dark on the second AC's phone and light on the
    /// director's is not a slate.
    @Test func theFaceIsDark() {
        #expect(html.contains("--face: #0c0c0e"), "the face is not dark")
        #expect(html.contains("--ink: #f4f4f0"), "the letters are not light")
        #expect(!html.contains("--face: #f2f2ee"),
                "the old light face is still in the palette")
    }

    /// **The flash goes the way the face does not.** It exists to be a
    /// luminance STEP an editor can find by scrubbing, so on a dark face it
    /// has to be white — a dark flash on a dark slate is no flash at all, and
    /// the two had to change together.
    @Test func theSyncFlashIsAStepAwayFromTheFace() {
        #expect(html.contains("#flash {\n  position: fixed; inset: 0; background: #fff;"),
                "the sync flash is not a step away from the face")
    }

    /// The roll is one of the things a camera is pointed at this face FOR, so
    /// it is a cell like the scene, the shot and the take — it used to be a
    /// dim caption in the footer, beside the connection lamp, which is chrome.
    @Test func theRollIsACellAndNotACaption() {
        #expect(html.contains("id=\"rollCell\""), "the roll has no cell")
        #expect(html.contains("id=\"vRoll\""))
        #expect(html.contains("el(\"kRoll\").textContent = S.roll"),
                "the roll's cell has no label")
        #expect(!html.contains("id=\"roll\"><"),
                "the old footer caption is still there")
    }

    /// **The tag heads the face rather than sitting on the readout.**
    ///
    /// It was `position: absolute; top: 0; right: 0` inside `#tcRow`, which is
    /// eleven monospaced characters wide on a face that is width-limited in
    /// portrait — so the capsule sat ON the last digits of the one thing this
    /// page exists to show (owner: "подпись sync как будто над хлопушкой
    /// должна быть а не в уголке у таймкода").
    ///
    /// Asserted INSIDE the rule's own body and against the markup's order,
    /// never over the whole page: the paragraph that explains this change
    /// names the old placement in prose, and a `contains` over the file would
    /// be satisfied by the explanation of the thing it is checking is gone.
    @Test func theStateTagHeadsTheFace() throws {
        let page = html
        let rule = try #require(Self.cssBody(of: "#tag", in: page),
                                "there is no #tag rule at all")
        #expect(rule.contains("align-self: center"),
                "the tag is not a line of the face: \(rule)")
        #expect(!rule.contains("position: absolute"),
                "the tag is still lifted out of the layout: \(rule)")
        // and it comes BEFORE the readout it used to sit inside
        let tag = try #require(page.range(of: "<div id=\"tag\">"))
        let row = try #require(page.range(of: "<div id=\"tcRow\">"))
        #expect(tag.lowerBound < row.lowerBound,
                "the tag is still inside or after the readout")
        // …and standby, which is the normal state between takes, does not
        // wear the amber a real warning wears
        let standby = try #require(Self.cssBody(of: "body.standby #tag", in: page))
        #expect(standby.contains("background: transparent"),
                "standby is dressed as a fault: \(standby)")
    }

    /// **The roll is the same size as the cells beside it** (owner: "почему
    /// неравновесно roll был добавлен?").
    ///
    /// It was `flex: 0 1 auto` with a `min-width` in `em` — the only length on
    /// a face otherwise stated entirely in `vw`/`vh` — so it did not scale
    /// with the slate: four-fifths of a sibling in portrait and under a third
    /// in landscape, the way a phone is actually held up to a lens.
    @Test func theRollIsTheSameSizeAsItsNeighbours() throws {
        let page = html
        let rule = try #require(Self.cssBody(of: "#rollCell", in: page),
                                "the roll's cell has no rule")
        #expect(!rule.contains("min-width"),
                "the roll is still floored in em: \(rule)")
        let cell = try #require(Self.cssBody(of: ".cell", in: page))
        let share = "flex: 1 1 0"
        #expect(rule.contains(share) && cell.contains(share),
                "the roll and its neighbours ask for different shares: \(rule)")
    }

    /// One CSS rule's body — everything between its brace and the next one.
    ///
    /// The house rule for tests that grep sources: assert inside the smallest
    /// region you can name. A `contains` over a whole page is satisfied by the
    /// comment ABOVE the rule, which on this page is a paragraph explaining
    /// exactly what the rule no longer says.
    private static func cssBody(of selector: String, in html: String) -> String? {
        guard let open = html.range(of: "\n\(selector) {"),
              let close = html.range(of: "}", range: open.upperBound..<html.endIndex)
        else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// **The state tags say what they mean.** STANDBY and HOLD were terms of
    /// art for two different kinds of "the number may be wrong" (owner: "и что
    /// там значит у таймкода стендбай и холд? неясно"), and OFFLINE said
    /// nothing about which link.
    @Test func theStateTagsAreReadableInBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            let words = ViewRender.withLanguage(language) {
                [L("slate_page_standby"), L("slate_page_hold"),
                 L("slate_page_offline")]
            }
            #expect(Set(words).count == 3,
                    Comment(rawValue: "\(language.rawValue) reuses a word: \(words)"))
            for word in words {
                #expect(!word.isEmpty)
                #expect(word == word.uppercased(),
                        Comment(rawValue: "\(word) is not the tag's voice"))
            }
        }
        // …and the two that are about the NUMBER both name it, so the reader
        // knows which fact is in doubt.
        #expect(ViewRender.withLanguage(.english) { L("slate_page_standby") }
            .contains("TC"))
        #expect(ViewRender.withLanguage(.english) { L("slate_page_hold") }
            .contains("TC"))
    }

    /// **A healthy readout carries no tag.** The last branch used to fall back
    /// to HOLD, so a live running clock had the word written into a hidden
    /// element — and the next person to make the tag visible would have
    /// shipped it.
    @Test func aLiveRunningClockHasNothingToSay() {
        #expect(html.contains("(standby ? S.standby : \"\")"),
                "the healthy state still falls back to a tag")
    }
}
