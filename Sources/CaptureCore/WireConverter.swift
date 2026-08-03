@preconcurrency import CoreVideo
import Foundation

/// The split every high-bit-depth wire format goes through, and the one
/// statement of the policy behind it.
///
/// `TenBitConverter` ('r210'), `TwelveBitConverter` ('R12B') and
/// `TenBitYUVConverter` ('v210') are the three implementations. They are
/// separate types rather than one converter with a bit-depth parameter because
/// almost nothing they do at the pixel level is shared — a 10-bit RGB pixel is
/// one aligned 32-bit word, a 12-bit one is a twenty-fourth of a 36-byte block,
/// a 10-bit YCbCr one is a sixth of a 16-byte block and shares its chroma with
/// its neighbour, and their record buffers are different pixel formats with
/// different measured VideoToolbox conventions. Folding them into one row loop
/// would put a branch on the wire format inside the hottest loop in the app for
/// no reuse worth having.
///
/// What IS shared is the part that matters, and it lives here rather than in any
/// of them: the rule that a wire frame becomes exactly two products, and the
/// display table that decides what the operator sees. That table used to be
/// built inside the 10-bit converter, and a second converter copying it is
/// precisely how two paths would drift into showing different blacks. The YCbCr
/// path goes through the very same table by converting colour SPACE without
/// touching swing first — see `WireYCbCr`.
public protocol WireConverter: AnyObject {
    /// The wire format this converter reads.
    var wireFormat: OSType { get }
    /// The pixel format of the buffer handed to the writer.
    var recordPixelFormat: OSType { get }
    /// Bytes per pixel of that record buffer — the pre-roll ring sizes itself
    /// from this, and a 12-bit take's record frame is twice a 10-bit one.
    var recordBytesPerPixel: Int { get }
    /// Whether a take written from this converter's record buffer has to be
    /// EXPANDED again on the way back out, i.e. whether it is tagged
    /// `com.takeshot.levels = "wire"` (see `TakeWriter.levelsKey`).
    ///
    /// True for the RGB formats and false for YCbCr, and the asymmetry is the
    /// point of asking rather than assuming. An RGB coded picture has no
    /// standard way to say "these codes are studio swing", so the app says it
    /// itself and expands on playback; a video-range YCbCr picture says it
    /// through the ordinary Rec.709 + video-range tags and every decoder already
    /// acts on them. Measured both ways — see `TenBitYUVConverter`. Getting this
    /// backwards expands a take twice and crushes exactly the shadows the wire
    /// record path exists to protect.
    var recordNeedsPlaybackExpansion: Bool { get }
    /// The resolved input-levels mode for the current source. Reaches the
    /// DISPLAY product only; see `WireDisplayTable`.
    func setLevels(_ levels: InputLevels)
    /// Split a wire frame into (display BGRA8, record).
    func convert(_ source: CVPixelBuffer)
        -> (display: CVPixelBuffer, record: CVPixelBuffer)?
}

/// The display half of the wire split, stated once for every bit depth.
///
/// The picture and the deliverable want opposite things from the same codes,
/// and this is the picture's half: studio swing puts nominal black on 0 and
/// nominal white on the top of the scale, and the camera's legal excursions
/// clip against those ends. An operator judges exposure against a black that is
/// black — expanding the whole legal swing instead put nominal black 6 % up the
/// scale on every monitor, which is the complaint that produced this rule.
///
/// Nothing is lost by clipping HERE. The excursions are in the recorded file
/// (each converter's record buffer carries the wire codes, built from the wire
/// code alone and never from this table) and on the scopes (they read the wire,
/// before the split). Those two are the reason this table may be opinionated.
enum WireDisplayTable {
    /// wire code → the value that appears on the DISPLAY, on the wire's own
    /// scale. The caller shifts it down to the 8 bits the BGRA buffer holds.
    ///
    /// `bits` is the wire's depth, so the table is `1 << bits` entries: 1024
    /// for 'r210' and for the R'G'B' a 'v210' frame has been matrixed into,
    /// 4096 for 'R12B'. Building it per depth rather than rescaling a 10-bit
    /// table keeps the 12-bit path's rounding honest at its own precision.
    static func expand(levels: InputLevels, bits: Int) -> [UInt16] {
        let top = (1 << bits) - 1
        let window = levels.wireWindow(bits: bits)
        let span = Double(window.white - window.black)
        return (0...top).map { code in
            guard levels != .full else { return UInt16(code) }
            let scaled = Double(code - window.black) * Double(top) / span + 0.5
            return UInt16(min(top, max(0, Int(scaled))))
        }
    }
}
