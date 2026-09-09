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
