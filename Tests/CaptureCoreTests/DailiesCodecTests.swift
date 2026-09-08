import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **The codec, the container and the extension are one decision.**
///
/// They used to be three literals in three files — `AVVideoCodecType.h264` in
/// the engine, `fileType: .mp4` in the session, `appendingPathExtension("mp4")`
/// in the transcode — with nothing linking them. The moment a codec became the
/// operator's choice that stopped being harmless: ProRes has no registered
/// MPEG-4 sample entry, so any pair that moves without the others produces a
/// file the writer refuses or a player cannot open.
@Suite struct DailiesCodecTests {
    @Test func proResGoesInAQuickTimeContainerAndH264InAnMP4() {
        #expect(CaptureCodec.h264.dailiesFileExtension == "mp4")
        #expect(CaptureCodec.hevc.dailiesFileExtension == "mp4")
        #expect(CaptureCodec.proResProxy.dailiesFileExtension == "mov")
        #expect(CaptureCodec.proResLT.dailiesFileExtension == "mov")
    }

    /// The extension on disk and the container inside the file are derived
    /// from the same answer, so they cannot disagree.
    @Test func theContainerAgreesWithTheExtensionForEveryChoice() {
        for codec in CaptureCodec.dailiesChoices {
            let expected: AVFileType =
                codec.dailiesFileExtension == "mp4" ? .mp4 : .mov
            #expect(codec.dailiesContainer == expected,
                    "\(codec.rawValue) writes .\(codec.dailiesFileExtension) into \(codec.dailiesContainer.rawValue)")
        }
    }

    /// A daily is a review copy. 422, HQ and 4444 produce a file at or above
    /// the size of the take it was made from, which is not a proxy.
    @Test func theChoicesAreTheOnesWorthMakingADailyIn() {
        #expect(CaptureCodec.dailiesChoices
            == [.h264, .hevc, .proResProxy, .proResLT])
        for heavy in [CaptureCodec.proRes422, .proResHQ, .proRes4444] {
            #expect(!CaptureCodec.dailiesChoices.contains(heavy),
                    "\(heavy.rawValue) is offered as a daily")
        }
    }

    @Test func theSettingsCarryTheChosenCodec() throws {
        for codec in CaptureCodec.dailiesChoices {
            let settings = DailiesEngine.videoSettings(
                size: CGSize(width: 1920, height: 1080), frameRate: 25,
                codec: codec)
            #expect(settings[AVVideoCodecKey] as? AVVideoCodecType
                == codec.avCodecType)
        }
    }

    /// **ProRes is not handed a bitrate**, and that is not an omission: its
    /// rate is a property of the picture and the flavour, and the key is
    /// either ignored or refused depending on the build.
    @Test func onlyTheRateControlledCodecsAreGivenABitrate() throws {
        let full = CGSize(width: 1920, height: 1080)
        for codec in CaptureCodec.dailiesChoices {
            let settings = DailiesEngine.videoSettings(
                size: full, frameRate: 25, codec: codec)
            let compression = settings[AVVideoCompressionPropertiesKey]
                as? [String: Any]
            if codec.needsBitrate {
                let bitrate = try #require(
                    compression?[AVVideoAverageBitRateKey] as? Int)
                #expect(bitrate == DailiesEngine.bitsPerSecondAt1080p)
            } else {
                #expect(compression == nil,
                        "\(codec.rawValue) was handed compression properties")
            }
        }
    }

    /// The HDR colour branch is codec-independent — it is about the SOURCE —
    /// and it had to survive the codec becoming a parameter.
    @Test func anHDRSourceStillStatesItsColourWhateverTheCodec() throws {
        // Rec.2020 primaries under a PQ curve — what the compositor hands the
        // encoder for an HDR take (see `videoSettings`).
        let hdr = WireColorimetry(transfer: .pq, primaries: .rec2020)
        for codec in CaptureCodec.dailiesChoices {
            let settings = DailiesEngine.videoSettings(
                size: CGSize(width: 1920, height: 1080), frameRate: 25,
                colorimetry: hdr, codec: codec)
            #expect(settings[AVVideoColorPropertiesKey] != nil,
                    "an HDR \(codec.rawValue) daily says nothing about its codes")
        }
        let sdr = DailiesEngine.videoSettings(
            size: CGSize(width: 1920, height: 1080), frameRate: 25,
            colorimetry: .sdr, codec: .proResLT)
        #expect(sdr[AVVideoColorPropertiesKey] == nil)
    }
}

/// The dailies settings that resolve rather than being read raw.
@Suite struct DailiesSettingsEffectiveTests {
    @Test func anUnsetCodecIsWhatEveryDailyUsedToBe() {
        #expect(DailiesSettings().codecEffective == .h264)
    }

    /// A blob naming something outside the offered list — a hand edit, or a
    /// codec that has since left `dailiesChoices` — lands on H.264 rather
    /// than starting a run that writes a daily bigger than the take.
    @Test func aCodecOutsideTheOfferedListFallsBack() {
        var settings = DailiesSettings()
        settings.codec = "ProRes 4444"
        #expect(settings.codecEffective == .h264)
        settings.codec = "not a codec"
        #expect(settings.codecEffective == .h264)
        settings.codec = "ProRes 422 LT"
        #expect(settings.codecEffective == .proResLT)
    }

    /// **The custom line's switch reads an older blob's intent.**
    ///
    /// The line used to have no flag: non-empty text WAS the on state. So a
    /// settings file from before the checkbox says nothing about a flag and
    /// everything about intent, and an upgrade must not quietly stop burning
    /// a line somebody was burning.
    @Test func anOldBlobWithACustomLineComesBackWithTheLineOn() {
        var carried = DailiesSettings()
        carried.customText = "INTERNAL - NOT FOR DISTRIBUTION"
        #expect(carried.burnCustomEffective)

        let untouched = DailiesSettings()
        #expect(!untouched.burnCustomEffective)

        // …and once the flag exists it is the authority, text or no text.
        var switchedOff = DailiesSettings()
        switchedOff.customText = "INTERNAL - NOT FOR DISTRIBUTION"
        switchedOff.burnCustom = false
        #expect(!switchedOff.burnCustomEffective)
    }

    @Test func theNameEndsDefaultToTheNameThisAppAlwaysWrote() {
        let settings = DailiesSettings()
        #expect(settings.namePrefixEffective.isEmpty)
        #expect(settings.nameSuffixEffective == "_DAILY")
    }

    @Test func anUnsetDatePositionIsWhereTheDateWasAlwaysDrawn() {
        #expect(DailiesSettings().datePositionEffective == .bottomRight)
    }
}
