import CaptureCore
import CoreMedia
import Foundation

/// VideoToolbox's output turned into what a transport stream carries.
///
/// The muxer's INPUT adapter, and the one file of it that knows about CoreMedia —
/// `MPEGTSMuxer` itself is pure Foundation so that a wire format can be tested as
/// bytes. The split is also what lets `SRTEncodeTests` measure a real encode: the
/// encoder hands out samples, and what a sample becomes is decided here.
///
/// Two conversions, and both are format rather than picture — no sample is
/// re-encoded here and no byte of a slice is touched.
///
/// **Length prefixes become start codes.** VideoToolbox hands back AVCC: each NAL
/// unit preceded by its length, usually in four bytes. MPEG-TS wants Annex B:
/// each NAL unit preceded by `00 00 00 01`. Same units, different framing, and
/// the length is read from the format description rather than assumed — it is
/// allowed to be one, two or four.
///
/// **Parameter sets are put in front of every keyframe.** In AVCC the SPS and PPS
/// live in the format description, out of band, because the container carries
/// them once. A transport stream has no such place: a receiver joining mid-stream
/// gets whatever bytes are arriving, so the sets have to be IN the stream, and
/// the keyframe is where they belong. This is what makes a director opening VLC
/// twenty minutes into a setup get a picture instead of a green rectangle.
extension MPEGTSMuxer {
    /// The four bytes that separate NAL units in Annex B.
    ///
    /// Four rather than three throughout. Three is legal and saves a byte per
    /// unit — about 30 bytes a frame, which is 0.006 kbit/s at 25 fps and not
    /// worth a second code path.
    static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// An access-unit delimiter, NAL type 9, `primary_pic_type` 7.
    ///
    /// Recommended by the transport-stream standard rather than required by any
    /// decoder: it says "a picture starts here" independently of the PES header
    /// that also says so. Six bytes a frame for a stricter demuxer's benefit.
    static let accessUnitDelimiter: [UInt8] = startCode + [0x09, 0xF0]

    /// One encoded sample as an access unit, or nil for a sample that carries
    /// nothing usable.
    static func accessUnit(from sample: CMSampleBuffer) -> AccessUnit? {
        guard let block: CMBlockBuffer = CMSampleBufferGetDataBuffer(sample),
              let format: CMFormatDescription =
              CMSampleBufferGetFormatDescription(sample) else { return nil }
        let keyframe: Bool = isKeyframe(sample)
        var payload: [UInt8] = accessUnitDelimiter
        if keyframe {
            payload += parameterSets(of: format)
        }
        guard let slices: [UInt8] = annexB(block, headerLength:
            nalUnitHeaderLength(of: format)) else { return nil }
        payload += slices
        let ticks: CMTime = CMTimeConvertScale(
            CMSampleBufferGetPresentationTimeStamp(sample),
            timescale: Int32(clockHz), method: .roundHalfAwayFromZero)
        return AccessUnit(payload: payload, pts: ticks.value,
                          isKeyframe: keyframe)
    }

    /// Whether a receiver can start here.
    ///
    /// Read as "not marked NotSync" rather than as "marked sync": VideoToolbox
    /// attaches the negative and omits it for a keyframe, and a sample with no
    /// attachments at all is a keyframe. Taking the absence of the positive would
    /// call every frame a keyframe and resend the tables 25 times a second.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments: CFArray = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0 else { return true }
        let raw: UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
        let first: CFDictionary = unsafeBitCast(raw, to: CFDictionary.self)
        guard let dictionary: [CFString: Any] = first as? [CFString: Any],
              let notSync: Bool = dictionary[
                  kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }

    /// How many bytes each length prefix takes. Four in practice; read rather
    /// than assumed, because the format description is where the answer is.
    static func nalUnitHeaderLength(of format: CMFormatDescription) -> Int {
        var header: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &header)
        return Int(header)
    }

    /// Every parameter set the format description holds, each with a start code.
    static func parameterSets(of format: CMFormatDescription) -> [UInt8] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil)
        var out: [UInt8] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus =
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { continue }
            out += startCode
            out += UnsafeBufferPointer(start: pointer, count: size)
        }
        return out
    }

    /// The sample's NAL units with their length prefixes replaced by start codes.
    ///
    /// The block buffer is COPIED rather than read in place. A CMBlockBuffer is
    /// allowed to be a chain of non-contiguous pieces, and
    /// `CMBlockBufferGetDataPointer` only ever hands back the run at the offset
    /// asked for — a walk over that pointer past the end of the first piece is a
    /// read into whatever is next in memory. One copy of about 40 KB a frame is
    /// not worth being clever about.
    static func annexB(_ block: CMBlockBuffer, headerLength: Int) -> [UInt8]? {
        let length: Int = CMBlockBufferGetDataLength(block)
        guard length > headerLength, headerLength > 0 else { return nil }
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                         destination: &avcc)
            == kCMBlockBufferNoErr else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(length + 8)
        var offset = 0
        while offset + headerLength <= length {
            var unit = 0
            for byte in 0..<headerLength {
                unit = unit << 8 | Int(avcc[offset + byte])
            }
            offset += headerLength
            guard unit > 0, offset + unit <= length else { break }
            out += startCode
            out += avcc[offset..<(offset + unit)]
            offset += unit
        }
        return out.isEmpty ? nil : out
    }
}
