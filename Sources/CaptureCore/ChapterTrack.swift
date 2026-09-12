@preconcurrency import AVFoundation
import Foundation

/// **A QuickTime chapter track: the format description, the input, and the
/// bytes of one chapter.**
///
/// Owner: "ого я не знал что так можно, конечно давай прокинем" — the markers
/// an operator flags during a take become chapters in the daily, so an editor
/// scrubbing the proxy lands on the moment somebody called out instead of
/// being handed a separate CSV of times to type in.
///
/// # What a chapter actually is
///
/// It is a TEXT track the picture points at. The video track carries a `chap`
/// track reference to it, every player follows that reference, and the text
/// track's samples are the chapter titles — each one running until the next
/// begins. There is no chapter media type; `AVAssetWriterInput`'s
/// `addTrackAssociation(withTrackOf:type:)` writes the reference, which is the
/// whole of what makes a text track a chapter list rather than a subtitle.
///
/// # The sample layout, which is where this goes wrong silently
///
/// A QuickTime text sample is a big-endian `UInt16` byte count, the text, and
/// then optional atoms. The atom that matters is `encd`, four bytes saying
/// which encoding the text was in: without it a reader is entitled to read
/// MacRoman, and every Cyrillic marker note in this bilingual app comes back
/// as mojibake — in a file nobody re-checks, because the ENGLISH ones look
/// right. `0x00000100` is what every writer that gets this right emits for
/// UTF-8.
///
/// # Why the container question does not arise
///
/// `TimecodeTrack` has a `canAdd` guard because an `.mp4` refuses a `tmcd`
/// track with an Objective-C exception no Swift `try` catches. Every daily is
/// a `.mov` now (owner: "давай и не рендерить в мп4. только в мовы все"), so
/// this one would never meet it — but the guard is here anyway, for the same
/// price and against the day something opens a writer on another container.
enum ChapterTrack {
    /// The encoding atom's value for UTF-8.
    static let utf8Encoding: UInt32 = 0x0000_0100

    /// The format description of a QuickTime text track, built from the
    /// sample description bytes the format defines.
    ///
    /// **`CMFormatDescriptionCreate` with no extensions is not enough** — the
    /// writer takes the input, takes the samples, and fails at
    /// `finishWriting` with `-12712`, "media format — invalid parameter".
    /// Measured, and worth recording because every step before the last one
    /// reports success: a text track's sample description is a fixed run of
    /// fields (justification, colours, a default text box, a font), and a
    /// description carrying none of them is not one.
    ///
    /// Every field is ZERO on purpose. They all describe how a player would
    /// DRAW the text, and a chapter title is never drawn — what reads this
    /// track reads the titles out of it. `nil` flavor is the QuickTime one.
    static func formatDescription() -> CMFormatDescription? {
        var description: CMTextFormatDescription?
        let bytes = descriptionData()
        let status = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress
            else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base, size: bytes.count,
                flavor: nil, mediaType: kCMMediaType_Text,
                formatDescriptionOut: &description)
        }
        guard status == noErr else { return nil }
        return description
    }

    /// The 60 bytes of a `'text'` sample description.
    ///
    /// The layout is the QuickTime file format's, and it is written out field
    /// by field rather than as a blob of zeroes so the next person can check
    /// it against the spec: the 16-byte sample-description header (size,
    /// format, six reserved bytes, a data-reference index of 1), then display
    /// flags, justification, a background colour, a default text box, eight
    /// reserved bytes, a font number and face, three more reserved bytes, a
    /// foreground colour, and an empty Pascal string for the font name.
    static func descriptionData() -> Data {
        var out = Data()
        func be32(_ value: UInt32) {
            out.append(contentsOf: withUnsafeBytes(of: value.bigEndian,
                                                   Array.init))
        }
        func be16(_ value: UInt16) {
            out.append(contentsOf: withUnsafeBytes(of: value.bigEndian,
                                                   Array.init))
        }
        be32(60)                                    // size
        out.append(contentsOf: Array("text".utf8))  // data format
        out.append(contentsOf: [UInt8](repeating: 0, count: 6))  // reserved
        be16(1)                                     // data reference index
        be32(0)                                     // display flags
        be32(0)                                     // text justification
        be16(0); be16(0); be16(0)                   // background colour
        be16(0); be16(0); be16(0); be16(0)          // default text box
        be32(0); be32(0)                            // reserved
        be16(0)                                     // font number
        be16(0)                                     // font face
        out.append(0)                               // reserved
        be16(0)                                     // reserved
        be16(0); be16(0); be16(0)                   // foreground colour
        out.append(0)                               // font name: empty
        return out
    }

    /// The input such a track needs, added to the writer and pointed at by
    /// `video` — or nil when the container will not take one.
    ///
    /// The association is what makes this a CHAPTER track; without it the file
    /// carries a text track no player looks for. It is made from the video
    /// input, and it has to be made BEFORE writing starts, like every other
    /// structural decision about a writer.
    static func input(for formatDescription: CMFormatDescription,
                      in writer: AVAssetWriter,
                      chapterOf video: AVAssetWriterInput) -> AVAssetWriterInput? {
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        // A chapter track is not the picture: it must never be the input a
        // player uses to decide what the file looks like.
        input.marksOutputTrackAsEnabled = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        video.addTrackAssociation(withTrackOf: input,
                                  type: AVAssetTrack.AssociationType.chapterList.rawValue)
        return input
    }

    /// One chapter covering `[from, until)`.
    ///
    /// An empty title is written as an empty string rather than skipped: a
    /// marker with no note is still a moment somebody flagged, and a chapter
    /// list with a gap where it should be is worse than one with a blank name
    /// — the editor at least lands on the frame.
    static func sample(title: String, formatDescription: CMFormatDescription,
                       from: CMTime, until: CMTime) -> CMSampleBuffer? {
        guard until > from else { return nil }
        let payload = data(for: title)
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0,
            blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        let written = payload.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard written == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTimeSubtract(until, from),
                                        presentationTimeStamp: from,
                                        decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// The bytes of one text sample: the length, the text, and the encoding
    /// atom that says the text is UTF-8.
    ///
    /// The count is the TEXT's byte count and not the sample's — a reader
    /// takes that many bytes and then looks for atoms in whatever is left, so
    /// counting the atom in would swallow it and truncate the title.
    static func data(for title: String) -> Data {
        let text = Data(title.utf8).prefix(Int(UInt16.max))
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt16(text.count).bigEndian,
                                               Array.init))
        out.append(text)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(12).bigEndian,
                                               Array.init))
        out.append(contentsOf: Array("encd".utf8))
        out.append(contentsOf: withUnsafeBytes(of: utf8Encoding.bigEndian,
                                               Array.init))
        return out
    }
}
