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
/// ## The poster beside the multiview stream
///
/// A live camera grid exists now (`/multiview`, owner-approved), and it was
/// built the way the objections recorded here said it would have to be: the
/// frames come off a second display-tap slot (`setOnMultiviewFrame`) rather
/// than the playout mirror's, they ride the WebSocket as binary messages
/// rather than a `multipart/x-mixed-replace` connection the HTTP side has no
/// model for, and the encoder exists only while a phone is subscribed — see
/// `MultiviewEncoder` and `RemoteClient+Multiview`.
///
/// The poster stays regardless, because it answers a different question. The
/// stream is "what is the camera seeing NOW"; the poster is "what did that
/// take look like" — a frame of footage that landed, shown next to the rating
/// buttons that act on it, at a cost of one cached thumbnail re-encoded when
/// a take finalizes.
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
