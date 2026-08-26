import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The one definition of what each picture is.**
///
/// The reason this suite exists at all is the failure it is guarding against,
/// which is not a crash: two code paths that each decide what "clean" means
/// drift, and the drift is invisible until a stream carries a burn-in that
/// should not be there. So what is pinned here is not behaviour so much as
/// SHAPE — every picture name resolves to a buffer through one switch, and the
/// wire words a phone sends come from the same enum the app switches on.
struct LivePictureTests {
    private func frame(_ width: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, 2,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        return try #require(buffer)
    }

    /// The subscript is the whole of the distinction, and it says three things.
    ///
    /// Identity rather than equality: what a consumer receives has to be the
    /// very buffer the frame path produced, not a copy that some second stage
    /// could have touched on the way.
    @Test func eachPictureNamesTheBufferItIsBuiltFrom() throws {
        let decorated: CVPixelBuffer = try frame(4)
        let clean: CVPixelBuffer = try frame(6)
        let live = LiveFrame(decorated: decorated, clean: clean)
        #expect(live[.decorated] === decorated)
        #expect(live[.clean] === clean)
        // The grid is composed OUT of the clean picture, one of these per
        // camera. That it shares clean's source here is what stops the grid
        // from becoming a second opinion about what clean means.
        #expect(live[.grid] === clean,
                "the grid is not built from the clean picture")
    }

    /// Where each picture's frames come from — the axis a camera choice would
    /// later arrive on.
    ///
    /// It matters that `.grid` is the odd one out: it is why the grid keeps
    /// moving while the operator scrubs a take, and it is why the two halves of
    /// `wireLivePictures` exist.
    @Test func eachPictureNamesItsSource() {
        #expect(LivePicture.decorated.source == .viewer)
        #expect(LivePicture.clean.source == .viewer)
        #expect(LivePicture.grid.source == .cameras)
    }

    /// The raw values are WIRE WORDS: a phone sends them in its offer and the
    /// page's buttons are built from them. Renaming a case renames the
    /// protocol, and this is where that gets noticed rather than on a handset.
    @Test func theWireWordsAreTheEnumsOwn() {
        #expect(LivePicture.allCases.map(\.rawValue)
                    == ["decorated", "clean", "grid"])
        #expect(LivePicture(rawValue: "clean") == .clean)
        #expect(LivePicture(rawValue: "Clean") == nil,
                "the wire words are case sensitive and must stay so")
        #expect(LivePicture(rawValue: "") == nil)
    }
}
