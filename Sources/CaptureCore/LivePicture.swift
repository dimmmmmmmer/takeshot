@preconcurrency import CoreVideo

/// **The pictures a live consumer may watch, and the one place that says what
/// each of them is.**
///
/// The app produces more than one picture of the same moment, and which one a
/// surface should get has never been one answer: the hardware monitor and the
/// SRT link exist to stand in for a cable to a director's monitor, so they take
/// what the operator is looking at; the phone camera grid is a crew monitoring
/// surface where the operator's own TOOLS would lie to it, so it takes the
/// camera's picture as framed and nothing else. Both rules were right and
/// both were written at their
/// own call sites, which is how "what does clean mean" drifts — and a stream
/// carrying a burn-in that should not be there is invisible until somebody
/// downstream complains about footage.
///
/// So the distinction is named ONCE, here, and every consumer picks by naming a
/// case rather than by knowing which buffer is which. `LiveFrame`'s subscript is
/// the only function in the app that turns one of these names into a buffer.
///
/// **Adding "which camera" later.** The axis a camera choice lives on is
/// `source` below, not this list: `.grid` is already the case whose frames come
/// from every board at once rather than from the surface the operator is
/// looking at, so a future "camera B, clean" is another `.cameras` picture and
/// not a new kind of thing. What it would cost is stated at `LiveFrameSource`.
public enum LivePicture: String, CaseIterable, Sendable {
    /// What the operator is looking at: the chroma key and the assists burned
    /// in, the reference wipe included. The picture the SRT output carries and
    /// the hardware monitor shows, and the one this seam has always sent.
    case decorated
    /// The same frame BEFORE the key and the assists, **carrying the settled
    /// framing and nothing else the operator switched on for themselves**.
    ///
    /// The levels and the viewing LUT are in it, because those are what make
    /// it a picture at all. The exposure tools, the guides, the legend, the
    /// chroma key and the compare wipe are not: a crew monitoring surface is
    /// watched by people who are not judging exposure, and every one of those
    /// would lie to them.
    ///
    /// **The FRAMING is, and that is the carve-out** (owner: "на телефоне
    /// пусть тоже будет кадрирование"). A desqueeze is not an opinion about
    /// the picture, it is what the picture IS — an anamorphic feed shown
    /// squeezed on a room of phones is not the camera's picture, it is a wrong
    /// one — and a flip is the way the camera is hung. What is left out is the
    /// magnification and its pan (`PictureSizing.settled`), which is where the
    /// operator drew the line: "всё кроме зума и пана". Those two are a moment
    /// in a shot, and an operator punching in to check focus must not take the
    /// whole unit's picture with them.
    ///
    /// That carve-out is also what keeps this safe for a grid. The sharpest
    /// rule against putting geometry on a tile is the composer's own — a tile
    /// cropped to its cell would hide the edges of a frame somebody is using
    /// to judge what is in shot — and a settled sizing cannot crop: `zoom` is
    /// 1, so `isCropping` is false by construction.
    case clean
    /// Every camera's `clean` picture at once, tiled into one frame.
    ///
    /// Composed rather than selected, which is why it is a picture and not a
    /// layout: one H.264 session carries the whole grid, so a room of phones
    /// watching it costs one encode between them.
    case grid

    /// Where this picture's frames come from.
    ///
    /// Two sources rather than two filters, and the difference is visible on
    /// set: `.viewer` is whatever the operator has in front of them — the live
    /// signal, a take under review, a RAW clip — so it follows them into
    /// playback; `.cameras` is every board's live signal, so the grid keeps
    /// moving while the operator scrubs a take. That is the right behaviour for
    /// both and it is not a preference either of them could have.
    ///
    /// **This is the seam a camera choice would arrive on.** A picture that
    /// names one board is a `.cameras` picture with an index on it; what it
    /// costs is the pool's key becoming a small struct of (picture, camera)
    /// instead of this enum, and the wire's `picture` field gaining a `camera`
    /// beside it. Nothing else moves — not this file's definitions, not the
    /// subscript, not the encoder pool's rule.
    public var source: LiveFrameSource {
        switch self {
        case .decorated, .clean: return .viewer
        case .grid: return .cameras
        }
    }
}

/// Which of the app's two frame sources a `LivePicture` is built from.
public enum LiveFrameSource: String, CaseIterable, Sendable {
    /// The one surface the operator is looking at, whatever it is showing.
    case viewer
    /// Every live camera at once.
    case cameras
}

/// One displayed frame, as both of the pictures it has.
///
/// **The stored buffers are private on purpose.** The only way out of this type
/// is to name a picture, so a consumer cannot reach for "the other one" and no
/// second opinion about which buffer is clean can exist. A struct of two class
/// references: passing it costs no allocation, which matters because this is on
/// the display queue at up to the pace ceiling.
public struct LiveFrame: Sendable {
    private let decorated: CVPixelBuffer
    private let clean: CVPixelBuffer

    public init(decorated: CVPixelBuffer, clean: CVPixelBuffer) {
        self.decorated = decorated
        self.clean = clean
    }

    /// The buffer this picture is built from — **the one place the distinction
    /// is made.**
    ///
    /// `.grid` answers with the clean buffer because that is what it is built
    /// OUT of: the composer tiles one of these per camera. It is deliberately
    /// not a fourth buffer here — this type is one camera's frame, and the grid
    /// is several of them.
    public subscript(picture: LivePicture) -> CVPixelBuffer {
        switch picture {
        case .decorated: return decorated
        case .clean, .grid: return clean
        }
    }
}
