@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// The two static-HDR payloads a take can carry beyond its nclc tags, packed
/// exactly as SMPTE ST 2086 and CTA-861.3 define them.
///
/// ## Why they are bytes and not a dictionary
///
/// The nclc colorimetry tags (`AVVideoColorPropertiesKey`) say what CURVE and
/// what PRIMARIES a file is in, and that is the part post cannot work without.
/// These two say something else: how bright the display the shot was graded on
/// could actually go (`mdcv`, the mastering display colour volume) and how
/// bright the content itself gets (`clli`, MaxCLL and MaxFALL). A grading suite
/// uses them to decide how much it has to tone map; without them it guesses.
///
/// VideoToolbox takes both as raw `CFData` in the layout the standards define —
/// there is no structured API — so the packing lives here, once, with the field
/// order written down. Getting the order wrong produces a file that is valid,
/// that no tool complains about, and that claims the mastering display had its
/// red primary where its green one is.
///
/// ## What is NOT here
///
/// Nothing in this file reaches a picture. The display transform is fixed (see
/// `HDRTransfer`) and deliberately does not consult MaxCLL: an operator's
/// reference has to be stable, and a monitor whose contrast changes because the
/// camera re-sent its metadata mid-shot is not a reference. This is the file's
/// half of the HDR job and only that.
extension TakeWriter {
    /// The compression-session properties that carry the static metadata into
    /// the file.
    /// Empty when there is nothing worth writing.
    static func hdrCompressionProperties(
        _ displayMetadata: HDRStaticMetadata) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let volume = displayColorVolume(displayMetadata) {
            properties[kVTCompressionPropertyKey_MasteringDisplayColorVolume
                as String] = volume
        }
        if let light = contentLightLevelInfo(displayMetadata) {
            properties[kVTCompressionPropertyKey_ContentLightLevelInfo
                as String] = light
        }
        return properties
    }

    /// SMPTE ST 2086, 24 bytes, big-endian throughout:
    ///
    /// - three primary xy pairs in **G, B, R order** (that is the standard's
    ///   order, not R, G, B — the one field-order mistake this payload invites),
    ///   each in units of 0.00002, i.e. the chromaticity times 50 000;
    /// - the white point xy, same units;
    /// - max and min mastering-display luminance, each a 32-bit value in units
    ///   of 0.0001 cd/m².
    ///
    /// nil when the board gave no primaries or no luminance range: a box full
    /// of zeros tells a colourist less than no box at all, because a zero
    /// mastering luminance reads as a claim rather than as a silence.
    static func displayColorVolume(
        _ displayMetadata: HDRStaticMetadata) -> Data? {
        guard let primaries = displayMetadata.displayPrimaries,
              displayMetadata.maxDisplayLuminance > 0 else { return nil }
        var data = Data(capacity: 24)
        func appendChromaticity(_ value: Double) {
            append16(&data, UInt16(clamping: Int((value * 50_000).rounded())))
        }
        for pair in [(primaries.greenX, primaries.greenY),
                     (primaries.blueX, primaries.blueY),
                     (primaries.redX, primaries.redY),
                     (primaries.whiteX, primaries.whiteY)] {
            appendChromaticity(pair.0)
            appendChromaticity(pair.1)
        }
        append32(&data,
                 UInt32(clamping: Int((displayMetadata.maxDisplayLuminance
                     * 10_000).rounded())))
        append32(&data,
                 UInt32(clamping: Int((max(0, displayMetadata.minDisplayLuminance)
                     * 10_000).rounded())))
        return data
    }

    /// CTA-861.3 content light level, 4 bytes big-endian: MaxCLL then MaxFALL,
    /// both whole cd/m². nil when the board reported neither.
    static func contentLightLevelInfo(
        _ displayMetadata: HDRStaticMetadata) -> Data? {
        guard displayMetadata.maxContentLightLevel > 0
            || displayMetadata.maxFrameAverageLightLevel > 0 else { return nil }
        var data = Data(capacity: 4)
        append16(&data, UInt16(clamping:
            Int(max(0, displayMetadata.maxContentLightLevel).rounded())))
        append16(&data, UInt16(clamping:
            Int(max(0, displayMetadata.maxFrameAverageLightLevel).rounded())))
        return data
    }

    private static func append16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
