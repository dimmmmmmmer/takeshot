import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What the phone is allowed to press, as opposed to what it can say.
///
/// Its own suite rather than three more assertions in `RemoteProtocolTests`:
/// that file is the WIRE — the frames, the PIN gate, the tarpit, the JSON — and
/// it is at its type-length ceiling. This is the same question the Mac's menus
/// answer with `.disabled(…)`, asked of the page that had no answer at all.
@Suite @MainActor struct RemoteReachTests {
    private func utf8(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .utf8), "the page is not UTF-8")
    }

    /// The phone greys what the Mac greys, off the two facts the status carries.
    ///
    /// The marker and the two rating buttons were ungated on this page while every surface on the
    /// Mac gated them — `AppCommands` on `isRecording`/`isReviewingSingleClip`
    /// and on `takes.isEmpty`, `MenuBarModel` on the same pair. The app answers
    /// a marker with nothing rolling by falling through both branches of
    /// `addMarker()`, and a rating with no takes by
    /// `guard let last = takes.last else { return }` — no toast, no error. So on
    /// a fresh shoot three of the four buttons were pressable and silent, and
    /// the remote was the thing that looked broken.
    ///
    /// Asserted against the served page because that is where the rule now
    /// lives, and the page is a bundle resource: a rename on either side of the
    /// contract would otherwise fail only on somebody's phone.
    @Test @MainActor func theButtonsGreyOnTheSameRulesTheMacUses() throws {
        let html = try utf8(RemotePage.html())
        #expect(html.contains("function refreshButtons()"),
                "the enablement rule is not stated in one place any more")
        #expect(html.contains(#"if (id === "marker") { return !!status.recording; }"#),
                "the marker button is pressable with nothing rolling")
        #expect(html.contains("return !!status.lastTakeId;"),
                "the rating buttons are pressable with no take to rate")
        #expect(html.contains(#"if (id === "rec") { return !!status.capturing; }"#),
                "the record button is pressable with no source running")
        // and the rule is asked from both paths, not copied into one of them
        let calls: Int = html.components(separatedBy: "refreshButtons();").count - 1
        #expect(calls == 2,
                "the rule is asked from \(calls) places, not from both paths")
        // the status really does carry both facts the rule reads
        let status = RemoteStatus()
        let json = status.json
        #expect(json.contains("\"recording\":"), "the status dropped `recording`")
        #expect(json.contains("\"lastTakeId\":"), "the status dropped `lastTakeId`")
    }
}
