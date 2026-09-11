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
    /// **Every daily is a QuickTime file** (owner: "давай и не рендерить в
    /// мп4. только в мовы все").
    ///
    /// H.264 and HEVC used to go into an `.mp4`, which cannot carry the take's
    /// metadata keys, a timecode track or a name on a sound track — three
    /// measured refusals of the MPEG-4 writer, and three of the things that
    /// make a daily worth conforming from. The codec is unchanged; only the
    /// box around it is.
    @Test func everyDailyGoesInAQuickTimeContainer() {
        for codec in CaptureCodec.dailiesChoices {
            #expect(codec.dailiesFileExtension == "mov",
                    "\(codec.rawValue) writes .\(codec.dailiesFileExtension)")
            #expect(codec.dailyCarriesQuickTimeExtras,
                    "\(codec.rawValue) cannot carry the take's own metadata")
        }
    }

    /// The extension on disk and the container inside the file are derived
    /// from the same answer, so they cannot disagree.
    @Test func theContainerAgreesWithTheExtensionForEveryChoice() {
        for codec in CaptureCodec.dailiesChoices {
            let expected: AVFileType =
                codec.dailiesFileExtension == "mp4" ? .mp4 : .mov
            #expect(expected == .mov, "a daily in a container that is not .mov")
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
        // …and an SDR source states its colour too, which it did not use to
        // (owner: "ток теги 1-1-1 полюбас должны быть"). Left unwritten, the
        // file took whatever the decoded buffer carried — the source's own
        // tags when a frame passed straight through, and NOTHING when it came
        // out of the scaling pool.
        let sdr = DailiesEngine.videoSettings(
            size: CGSize(width: 1920, height: 1080), frameRate: 25,
            colorimetry: .sdr, codec: .proResLT)
        let stated: [String: Any] = try #require(
            sdr[AVVideoColorPropertiesKey] as? [String: Any],
            "an SDR daily says nothing about its codes")
        #expect(stated[AVVideoColorPrimariesKey] as? String
            == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(stated[AVVideoTransferFunctionKey] as? String
            == AVVideoTransferFunction_ITU_R_709_2)
        #expect(stated[AVVideoYCbCrMatrixKey] as? String
            == AVVideoYCbCrMatrix_ITU_R_709_2)
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

/// **How solid a burn-in is** — the plate and the lettering, separately, and
/// separately again for the custom line (owner: "хотелось бы еще иметь
/// возможность настроить опасити подложки и опасити самого текста… отдельно
/// для технических штук и отдельно для кастом тайтла").
@Suite struct DailiesInkTests {
    @Test func theStandardInkIsWhatEveryDailyHasCarried() {
        #expect(DailiesInk.standard.plate == 0.55)
        #expect(DailiesInk.standard.text == 1)
        #expect(DailiesSettings().inkEffective == .standard)
        #expect(DailiesSettings().customInkEffective == .standard)
    }

    /// A hand-edited blob cannot produce a colour nobody can see through.
    ///
    /// Asserted on `clamped` and not on the colours: `CGColor` clamps an
    /// out-of-range alpha itself, so a test that read `.alpha` passed with the
    /// clamp deleted — which is how the first version of this went green
    /// against a mutation.
    @Test func anOutOfRangeOpacityIsClamped() throws {
        #expect(DailiesInk(plate: 4, text: -2).clamped
            == DailiesInk(plate: 1, text: 0))
        #expect(DailiesInk(plate: 0.3, text: 0.7).clamped
            == DailiesInk(plate: 0.3, text: 0.7), "a sane ink was moved")
    }

    /// The two groups are independent: a watermark across the middle can be
    /// nearly plateless while the timecode on the edge stays readable.
    @Test func theTwoGroupsResolveIndependently() {
        var settings = DailiesSettings()
        settings.customPlateOpacity = 0
        settings.customTextOpacity = 0.4
        #expect(settings.customInkEffective == DailiesInk(plate: 0, text: 0.4))
        #expect(settings.inkEffective == .standard,
                "the custom line's dials moved the technical lines")

        settings.plateOpacity = 0.9
        #expect(settings.inkEffective.plate == 0.9)
        #expect(settings.customInkEffective.plate == 0,
                "the technical dials moved the custom line")
    }

    /// **The ink reaches the drawn strips.** A watermark asked for no plate
    /// has to come out with no plate — the setting existing is not the same as
    /// the compositor reading it.
    @Test func theCustomLinesInkIsWhatItsStripIsDrawnWith() throws {
        var burnins = DailiesBurnins()
        burnins.customText = "WATERMARK"
        burnins.customPosition = .center
        burnins.customInk = DailiesInk(plate: 0, text: 0.35)
        let texts = burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/x.mov"), outputName: "x",
            clipName: "A001C001"))
        #expect(texts.customInk == DailiesInk(plate: 0, text: 0.35))
        #expect(texts.ink == .standard)
        // …and the frame it draws is a frame: the strip is placed, so the ink
        // it carries is the ink that plate is filled with.
        let overlay = DailiesOverlay(size: CGSize(width: 1920, height: 1080),
                                     texts: texts)
        let custom = try #require(overlay.layout.custom)
        #expect(abs(custom.midY - 540) < 2, "the watermark is not centred")
    }

    /// **The drawn strip is the proof**, and the data assertion above is not:
    /// a compositor that handed every strip the technical ink would satisfy
    /// `texts.customInk` perfectly. So this renders a frame with the two inks
    /// as far apart as they go — a solid technical plate, none at all for the
    /// custom line — and reads the pixels back.
    @Test func theTwoInksProduceTwoDifferentPlates() throws {
        var burnins = DailiesBurnins()
        // The timecode is IN: its plate is the one re-filled every frame
        // rather than pre-rendered, so it is a second reader of the technical
        // ink and the one a mutation can point at the wrong group unseen.
        burnins.timecode = true
        burnins.timecodePosition = .topCenter
        burnins.project = false
        burnins.clipName = true
        burnins.clipNamePosition = .topLeft
        burnins.customText = "WATERMARK"
        burnins.customPosition = .bottomLeft
        burnins.ink = DailiesInk(plate: 1, text: 1)
        burnins.customInk = DailiesInk(plate: 0, text: 1)
        let texts = burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/x.mov"), outputName: "x",
            clipName: "A001C001"))

        let size = CGSize(width: 640, height: 360)
        let image = try #require(DailiesOverlay.previewImage(
            size: size, texts: texts,
            background: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        let overlay = DailiesOverlay(size: size, texts: texts)
        let technical = try #require(overlay.layout.clipName)
        let custom = try #require(overlay.layout.custom)

        // A point inside each plate, clear of the lettering: the strips are
        // left-aligned with a text inset, so the far right of each is plate.
        let opaque = try #require(Self.pixel(
            in: image, x: Int(technical.maxX - 3), y: Int(technical.midY)))
        let transparent = try #require(Self.pixel(
            in: image, x: Int(custom.maxX - 3), y: Int(custom.midY)))
        #expect(opaque.red < 0.2,
                "the technical plate is not solid: \(opaque)")
        #expect(transparent.red > 0.8,
                "the custom line drew a plate it was told not to: \(transparent)")

        // …and the running timecode's plate, which is filled per frame from
        // its own held colour rather than pre-rendered with the others.
        let clock = try #require(overlay.layout.timecode)
        let clockPlate = try #require(Self.pixel(
            in: image, x: Int(clock.minX + 2), y: Int(clock.midY)))
        #expect(clockPlate.red < 0.2,
                "the timecode plate is not the technical ink: \(clockPlate)")
    }

    /// One pixel of a rendered frame, in image coordinates (origin top-left).
    private static func pixel(in image: CGImage, x: Int,
                              y: Int) -> (red: Double, alpha: Double)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < CFDataGetLength(data) else { return nil }
        // premultipliedFirst, byteOrder32Little — the layout `previewImage`
        // asks CoreGraphics for: B G R A in memory.
        return (red: Double(bytes[offset + 2]) / 255,
                alpha: Double(bytes[offset + 3]) / 255)
    }
}

/// **The preview's background frame.**
///
/// A plate's opacity and a watermark's lettering cannot be judged against flat
/// grey (owner: "хотелось бы чтобы картинкой встал как пример какой-то один
/// стилл из любого исходника… вместо серого фона"), so the preview lays its
/// strips over a real frame when the app has one.
@Suite struct DailiesPreviewBackgroundTests {
    private func solid(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// **It COVERS the frame.** Letterbox bars are not part of the picture the
    /// strips will sit on, so a source of any aspect fills the preview and the
    /// overflow is cropped — judging a plate against a black bar would be
    /// judging it against nothing.
    @Test func aFrameOfAnyAspectCoversThePreview() {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        for (width, height) in [(1920, 1080), (1080, 1920), (640, 360),
                                (4096, 1716), (100, 3000)] {
            guard let image = solid(width: width, height: height) else {
                Issue.record("could not build a \(width)x\(height) fixture")
                continue
            }
            let rect = DailiesOverlay.fill(frame, with: image)
            #expect(rect.width >= frame.width - 0.01,
                    Comment(rawValue: "\(width)x\(height) left a gap: \(rect)"))
            #expect(rect.height >= frame.height - 0.01,
                    Comment(rawValue: "\(width)x\(height) left a gap: \(rect)"))
            // …centred, so the crop takes the same off both sides.
            #expect(abs(rect.midX - frame.midX) < 0.01)
            #expect(abs(rect.midY - frame.midY) < 0.01)
            // …and the aspect is kept: a stretched still is a lie about the
            // framing the burn-ins are being judged against.
            let sourceAspect = Double(width) / Double(height)
            #expect(abs(rect.width / rect.height - sourceAspect) < 0.01,
                    Comment(rawValue: "\(width)x\(height) was stretched: \(rect)"))
        }
    }

    /// A degenerate image cannot produce a rect nothing can be drawn into.
    @Test func aZeroSizedFrameFallsBackToTheWholePreview() throws {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let image = try #require(solid(width: 8, height: 8))
        #expect(DailiesOverlay.fill(frame, with: image).width >= frame.width)
    }

    /// The frame actually reaches the rendered preview — the picture behind
    /// the strips is the still and not the flat colour.
    @Test func theStillIsWhatIsBehindTheStrips() throws {
        let still = try #require(solid(width: 320, height: 180))
        var burnins = DailiesBurnins()
        burnins.timecode = false
        burnins.clipName = false
        burnins.project = false
        let texts = burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/x.mov"), outputName: "x",
            clipName: "A001C001"))
        let image = try #require(DailiesOverlay.previewImage(
            size: CGSize(width: 320, height: 180), texts: texts,
            background: CGColor(gray: 0.22, alpha: 1), backgroundImage: still))
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        // Middle of the frame, where nothing is burned in: B G R A little.
        let offset = 90 * image.bytesPerRow + 160 * 4
        let green = Double(bytes[offset + 1]) / 255
        #expect(green > 0.4, "the preview is still flat grey: green=\(green)")
    }
}
