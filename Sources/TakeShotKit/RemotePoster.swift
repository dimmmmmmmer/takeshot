import AppKit
import Foundation

/// The last take's frame, small enough to cross a set network and be on the
/// director's phone before they have finished looking up from the camera.
///
/// Its own type rather than a method on the controller: turning an image into
/// JPEG bytes needs no app state, and a free function is one a test can hand a
/// known picture and read the bytes back out of. The image itself is the takes
/// panel's own thumbnail — see `CaptureController.remoteTakePoster`.
///
/// ## Why this is a still and not a live MJPEG stream
///
/// A one-client, PIN-gated MJPEG preview off the display tap was considered and
/// is deliberately not built. It was only ever worth having if it stayed small,
/// and nothing about it does:
///
/// - **There is no frame-out seam to take it from.** `PreviewSinkRegistry` is
///   typed to `MetalPreviewLayer`, a concrete CALayer — a sink is a view's own
///   layer, not a frame consumer. Streaming means opening that up in
///   `CaptureCore`, on the preview path, which is the load-bearing side of the
///   capture queue rather than a corner of the remote.
/// - **The other tap is already owned.** `CapturePipeline.displayFrameHandler`
///   is a single slot behind a lock, held by the hardware playout mirror and
///   re-routed on every record/playback switch. Taking it is taking the
///   operator's monitor output away.
/// - **The connection model is wrong for it.** Every HTTP answer here is
///   `writeAndClose`. A `multipart/x-mixed-replace` body is an open connection
///   with no end, against a cap of eight, on a phone that can walk out of Wi-Fi
///   without sending a FIN — a second backpressure story to get right beside
///   the one the socket already has.
/// - **It is continuous encode work on a machine that is recording.** A poster
///   is one JPEG per take; a stream is one per frame, forever, for the sake of
///   a picture nobody watches between takes.
///
/// What the phone actually needed from a stream — "what did that take look
/// like" — is what the poster answers, at a cost that is one cached thumbnail
/// re-encoded when a take lands.
enum RemotePoster {
    /// Longest edge of the served image.
    ///
    /// The take thumbnails are decoded at 256 today (`requestThumbnail`), so
    /// this is a ceiling nobody currently meets rather than a resize. It is
    /// here so that a larger thumbnail later does not quietly start pushing a
    /// megabyte at a phone on set Wi-Fi once per take.
    static let maximumEdge: CGFloat = 640
    /// JPEG quality. A poster answers "which take is this" at arm's length; it
    /// is not a deliverable, and the grabs that are never come through here.
    static let quality = 0.6

    /// `image` as JPEG bytes, or nil when it holds nothing that can be drawn.
    ///
    /// Redrawn into an opaque bitmap rather than re-wrapped around whatever rep
    /// the decoder produced. An NSImage arriving from a still or a RAW bridge
    /// may carry alpha, JPEG has no way to represent it, and
    /// `representation(using: .jpeg)` answers that by returning nil on some
    /// inputs and compositing against undefined pixels on others — a poster
    /// that is intermittently nil or magenta is a support call from a set.
    static func jpeg(from image: NSImage, maxEdge: CGFloat = maximumEdge,
                     quality: Double = quality) -> Data? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed,
                                         context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }
        let longest = CGFloat(max(source.width, source.height))
        let scale = min(1, maxEdge / longest)
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))

        // Three samples in thirty-two bits: opaque, so JPEG can represent it,
        // and padded, so CoreGraphics can draw into it. A packed 24-bit rep is
        // the obvious way to write this and it does not work — CGBitmapContext
        // supports no 24-bit format at all, so `NSGraphicsContext` hands back
        // nil and the poster is silently never served.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        // Drawn straight into the rep's own CGContext: nothing here needs the
        // AppKit focus stack, and pushing the current context would make this
        // care which thread it is on.
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0,
                                                  width: width, height: height))
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
    }
}
