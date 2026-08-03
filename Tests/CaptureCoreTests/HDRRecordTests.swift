@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import CaptureCore

/// What an HDR take says about itself, measured through a real ProRes encode
/// rather than argued from AVFoundation's documentation.
///
/// The record path itself is deliberately UNCHANGED by HDR: a PQ or HLG frame
/// carries studio-swing wire codes exactly as an SDR one does, and the wire-code
/// rule (`WireConverter`) does not care what a code means. What changes is what
/// the FILE says about those codes — and that half has to be right or post reads
/// a PQ picture through a Rec.709 curve and gets an image a hundred times too
/// dark.
///
/// Synthetic throughout: there is no HDR camera here, so the wire frames are
/// hand-built PQ codes. What only hardware can answer is stated in the report.
struct HDRRecordTests {
    private static let frameWidth = 192
    private static let frameHeight = 64
    /// Nominal black, BT.2408's HDR reference grey, and diffuse white, as
    /// 10-bit studio-swing PQ wire codes.
    private static var bands: [Int] {
        [V210Fixtures.nominalBlack,
         wireCode(ofNits: HDRTransfer.referenceGreyNits),
         wireCode(ofNits: HDRTransfer.referenceWhiteNits)]
    }

    /// A luminance as a studio-swing 10-bit PQ code.
    static func wireCode(ofNits nits: Double) -> Int {
        let signal = HDRTransfer.pqSignal(nits)
        return Int((64 + signal * 876).rounded())
    }

    private func bandedFrame() throws -> CVPixelBuffer {
        let bands = Self.bands
        let bandWidth = Self.frameWidth / bands.count
        return try V210Fixtures.makeGrey(width: Self.frameWidth,
                                         height: Self.frameHeight) { x, _ in
            bands[min(bands.count - 1, x / bandWidth)]
        }
    }

    /// A wire frame recorded exactly the way the pipeline records one, with the
    /// colorimetry a PQ source would force on the file.
    private func encode(_ wire: CVPixelBuffer, colorimetry: WireColorimetry,
                        name: String, in root: URL) async throws -> URL {
        let converter = TenBitYUVConverter()
        converter.setLevels(.limited)
        converter.setColorimetry(colorimetry)
        let split = try #require(converter.convert(wire))
        let url = root.appendingPathComponent("\(name).mov")
        let format = CaptureFormat(width: CVPixelBufferGetWidth(wire),
                                   height: CVPixelBufferGetHeight(wire),
                                   frameRate: 25, timecodeFPS: 25, name: name,
                                   isRGB444: false, bitDepth: 10)
        let writer = try TakeWriter(
            url: url, format: format, codec: .proResHQ, startTimecode: nil,
            colorTagPreset: colorimetry.filePreset,
            displayMetadata: colorimetry.displayMetadata)
        for frame in 0..<6 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: split.record, pts: pts),
                  attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await writer.finish()
    }

    private static func extensions(of url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let description = try #require(
            try await track.load(.formatDescriptions).first)
        return CMFormatDescriptionGetExtensions(description)
            as? [String: Any] ?? [:]
    }

    private static func middleRowLuma(of url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                V210Packing.pixelFormat])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let row = base.advanced(by: (frameHeight / 2)
            * CVPixelBufferGetBytesPerRow(buffer))
        return (0..<CVPixelBufferGetWidth(buffer)).map {
            V210Packing.pixel(UnsafeRawPointer(row), x: $0).luma
        }
    }

    /// The measurement post depends on: a PQ take states PQ, Rec.2020 primaries
    /// and the Rec.2020 matrix, and it states them in the format description
    /// where every tool looks. These are the app's own tags going into the file
    /// and coming back out, so the assertion is about this app rather than
    /// about the host's encoder.
    @Test func aPQTakeSaysItIsPQ() async throws {
        let root = TestMedia.scratchDirectory("HDRRecordTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await encode(
            try bandedFrame(),
            colorimetry: WireColorimetry(transfer: .pq, primaries: .rec2020),
            name: "pq", in: root)
        let extensions = try await Self.extensions(of: url)
        func tag(_ key: CFString) -> String? {
            extensions[key as String] as? String
        }
        #expect(tag(kCMFormatDescriptionExtension_TransferFunction)
            == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String),
                "transfer: \(String(describing: tag(kCMFormatDescriptionExtension_TransferFunction)))")
        #expect(tag(kCMFormatDescriptionExtension_ColorPrimaries)
            == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String))
        #expect(tag(kCMFormatDescriptionExtension_YCbCrMatrix)
            == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String))
        // still video range, exactly like every other take: HDR changes what
        // the codes mean, not how far they swing
        #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo as String]
            == nil, "the file claims full range: \(extensions)")
    }

    /// The same for HLG, which is a different transfer constant on the same
    /// primaries and the same matrix.
    @Test func anHLGTakeSaysItIsHLG() async throws {
        let root = TestMedia.scratchDirectory("HDRRecordHLG")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await encode(
            try bandedFrame(),
            colorimetry: WireColorimetry(transfer: .hlg, primaries: .rec2020),
            name: "hlg", in: root)
        let extensions = try await Self.extensions(of: url)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String]
            as? String == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String]
            as? String == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String))
    }

    /// The wire-code rule survives HDR: tagging a file PQ does not move a
    /// single code in it.
    ///
    /// Written as a comparison of two files rather than against absolute
    /// numbers on purpose — both are encoded by whatever host is running the
    /// suite, so the question being asked is "did the tag change the pixels",
    /// which is a property of this app and not of macOS 15 versus 26.
    @Test func theTagsDoNotMoveTheCodes() async throws {
        let root = TestMedia.scratchDirectory("HDRRecordCodes")
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = try bandedFrame()
        let sdr = try await encode(wire, colorimetry: .sdr, name: "sdr",
                                   in: root)
        let pq = try await encode(
            wire, colorimetry: WireColorimetry(transfer: .pq,
                                               primaries: .rec2020),
            name: "pq", in: root)
        let sdrLuma = try await Self.middleRowLuma(of: sdr)
        let pqLuma = try await Self.middleRowLuma(of: pq)
        print("HDR record: 709-tagged \(Array(sdrLuma.prefix(4))), "
            + "PQ-tagged \(Array(pqLuma.prefix(4)))")
        #expect(sdrLuma == pqLuma,
                "the colour tags changed the coded picture")
        // and the codes are the ones the camera sent
        let bandWidth = Self.frameWidth / Self.bands.count
        for (index, sent) in Self.bands.enumerated() {
            let read = pqLuma[index * bandWidth + bandWidth / 2]
            #expect(abs(read - sent) <= 1,
                    "band \(index): sent \(sent), read \(read)")
        }
    }

    /// The reference static metadata used by the two tests below — BT.2100's
    /// primaries on a 1000 cd/m² display, which is what a camera flagging PQ
    /// over HDMI typically sends.
    static let referenceMetadata = HDRStaticMetadata(
        maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400,
        maxDisplayLuminance: 1000, minDisplayLuminance: 0.005,
        displayPrimaries: HDRStaticMetadata.Chromaticities(
            redX: 0.708, redY: 0.292, greenX: 0.170, greenY: 0.797,
            blueX: 0.131, blueY: 0.046, whiteX: 0.3127, whiteY: 0.3290))

    /// The writer ASKS the encoder for the two static-HDR boxes, with the bytes
    /// the standards define.
    ///
    /// Asserted on the settings dictionary rather than on the finished file,
    /// and that is deliberate. Whether a given macOS ProRes encoder emits the
    /// boxes is the host's behaviour — the same class of thing that made an
    /// earlier test in this project green here and red on CI — while whether
    /// this app asks for them is the app's, and the app's is what a test may
    /// pin. The file is measured in the test below, which prints what it found
    /// instead of asserting a host into place.
    @Test func theWriterAsksTheEncoderForTheStaticMetadata() throws {
        let format = CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                                   timecodeFPS: 25, name: "1080p25")
        let settings = TakeWriter.videoSettings(
            format: format, codec: .proResHQ, colorTagPreset: ColorTags.pqPreset,
            displayMetadata: Self.referenceMetadata)
        let compression = try #require(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        let volume = compression[
            kVTCompressionPropertyKey_MasteringDisplayColorVolume as String]
        let light = compression[
            kVTCompressionPropertyKey_ContentLightLevelInfo as String]
        #expect(volume as? Data
            == TakeWriter.displayColorVolume(Self.referenceMetadata))
        #expect(light as? Data
            == TakeWriter.contentLightLevelInfo(Self.referenceMetadata))
        // …and an SDR take asks for neither, so nothing that ships today gains
        // a compression dictionary it did not have
        let sdr = TakeWriter.videoSettings(format: format, codec: .proResHQ,
                                           colorTagPreset: nil)
        #expect(sdr[AVVideoCompressionPropertiesKey] == nil)
    }

    /// What the encoder on THIS host does with those properties, and the one
    /// thing that has to be true on every host: asking for them must not change
    /// the coded picture.
    ///
    /// The presence of the boxes is printed, not asserted — see the test above.
    /// Measured on macOS 26 at the time of writing: both `mdcv` and `clli`
    /// reach the format description of a ProRes 422 HQ file.
    @Test func theStaticMetadataCostsThePictureNothing() async throws {
        let root = TestMedia.scratchDirectory("HDRRecordMastering")
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = try bandedFrame()
        let plain = try await encode(
            wire, colorimetry: WireColorimetry(transfer: .pq,
                                               primaries: .rec2020),
            name: "plain", in: root)
        let tagged = try await encode(
            wire,
            colorimetry: WireColorimetry(transfer: .pq, primaries: .rec2020,
                                         displayMetadata: Self.referenceMetadata),
            name: "displayMetadata", in: root)
        let extensions = try await Self.extensions(of: tagged)
        let volume = extensions[
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String]
        let light = extensions[
            kCMFormatDescriptionExtension_ContentLightLevelInfo as String]
        print("HDR record: mdcv \(volume == nil ? "absent" : "present"), "
            + "clli \(light == nil ? "absent" : "present")")
        // whatever the host did with the boxes, the picture is untouched
        let plainLuma = try await Self.middleRowLuma(of: plain)
        let taggedLuma = try await Self.middleRowLuma(of: tagged)
        #expect(plainLuma == taggedLuma,
                "the static metadata changed the coded picture")
        // the transfer tag is still there beside them
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String]
            as? String
            == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String))
    }

    /// The packing itself, checked against the standards rather than against
    /// whatever the encoder happens to accept: ST 2086 is 24 bytes with the
    /// primaries in G, B, R order, and CTA-861.3's light level is 4.
    @Test func theStaticMetadataIsPackedAsTheStandardsDefineIt() throws {
        let displayMetadata = Self.referenceMetadata
        let volume = try #require(
            TakeWriter.displayColorVolume(displayMetadata))
        #expect(volume.count == 24)
        func word(_ index: Int) -> Int {
            Int(volume[index]) << 8 | Int(volume[index + 1])
        }
        // G first, then B, then R — the standard's order, and the one field
        // mistake this payload invites
        #expect(word(0) == Int((0.170 * 50_000).rounded()))
        #expect(word(2) == Int((0.797 * 50_000).rounded()))
        #expect(word(4) == Int((0.131 * 50_000).rounded()))
        #expect(word(8) == Int((0.708 * 50_000).rounded()))
        #expect(word(12) == Int((0.3127 * 50_000).rounded()))
        let maxLuminance = (0..<4).reduce(0) { $0 << 8 | Int(volume[16 + $1]) }
        #expect(maxLuminance == 10_000_000) // 1000 cd/m² in units of 0.0001
        let light = try #require(TakeWriter.contentLightLevelInfo(displayMetadata))
        #expect(light.count == 4)
        #expect(Int(light[0]) << 8 | Int(light[1]) == 1000)
        #expect(Int(light[2]) << 8 | Int(light[3]) == 400)
        // nothing to say means no box: a clli full of zeros claims a black
        // picture rather than saying nothing
        #expect(TakeWriter.contentLightLevelInfo(HDRStaticMetadata()) == nil)
        #expect(TakeWriter.displayColorVolume(HDRStaticMetadata())
            == nil)
    }
}
