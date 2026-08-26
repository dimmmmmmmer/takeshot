@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What an HDR take looks like once it has been baked to a review proxy.
///
/// The gap this closes was a measurement, not a theory: AVFoundation does not
/// tone map on decode, so a PQ take run through the dailies transcode came out
/// through a Rec.709 curve — diffuse white on 148 of 255 where the live monitor
/// put it on 242, the same footage a stop and a half apart. The fix is not a
/// second tone map: it is `StudioSwing.playbackTable`, the very table the
/// player applies to the very same file, so a proxy cannot disagree with the
/// review it was made from.
///
/// Every expectation here is computed from the LIVE display table rather than
/// written down as a number, which is what makes "the proxy agrees with the
/// monitor" the thing under test instead of "the proxy matches a constant
/// somebody typed".
struct DailiesToneMapTests {
    private static let raster = CGSize(width: 960, height: 540)

    /// Where the live display puts one luminance, on the 0…255 scale the
    /// proxy is coded on — the number the operator saw while this was shot.
    private static func onTheMonitor(_ nits: Double,
                                     transfer: SignalTransfer) throws -> Int {
        let signal: Double = try #require(
            transfer.signal(forNits: nits),
            "an SDR transfer has no signal for a luminance")
        let wire = Int((64 + signal * 876).rounded())
        let live: [UInt16] = WireDisplayTable.table(levels: .limited, bits: 10,
                                                    transfer: transfer)
        return Int(live[wire]) >> 2
    }

    /// Where the same luminance lands when nothing tone maps it: the decoder's
    /// own video-range expansion and nothing else. This is what the dailies
    /// transcode used to produce, and it is the value each assertion below has
    /// to be far away from for the assertion to mean anything.
    private static func leftAlone(_ nits: Double,
                                  transfer: SignalTransfer) throws -> Int {
        let signal: Double = try #require(
            transfer.signal(forNits: nits),
            "an SDR transfer has no signal for a luminance")
        let wire = Int((64 + signal * 876).rounded())
        return min(255, max(0, Int(((Double(wire) - 64) * 255 / 876).rounded())))
    }

    /// One HDR take through the whole engine, decoded back: the mean level of
    /// the picture between the strips.
    private func proxyWhite(transfer: SignalTransfer, root: URL) async throws
        -> Double {
        let source = try await DailiesRig.writeHDRTake(
            at: root.appendingPathComponent("hdr.mov"), transfer: transfer,
            nits: HDRTransfer.referenceWhiteNits,
            width: Int(Self.raster.width), height: Int(Self.raster.height))
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the HDR take produced no daily")
        let frame = try await DailiesRig.decodeFrame(0, of: daily)
        return DailiesRig.meanLevel(frame,
                                    in: DailiesRig.centerRegion(of: Self.raster))
    }

    /// The measurement the whole change exists for. Diffuse white in a PQ take
    /// reaches the proxy where the live monitor put it, not a stop and a half
    /// below it.
    @Test func aPQTakeReachesTheProxyWhereTheLiveMonitorPutIt() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let white = try await proxyWhite(transfer: .pq, root: root)
        let monitor = try Self.onTheMonitor(HDRTransfer.referenceWhiteNits,
                                            transfer: .pq)
        let untouched = try Self.leftAlone(HDRTransfer.referenceWhiteNits,
                                           transfer: .pq)
        #expect(abs(white - Double(monitor)) <= 4,
                "PQ diffuse white reached the proxy at \(white), monitor \(monitor)")
        #expect(white - Double(untouched) > 40,
                "PQ diffuse white is still near the untone-mapped \(untouched): \(white)")
    }

    /// The same for HLG, which gets there down a different curve — the OOTF
    /// is what makes the two agree at all.
    @Test func anHLGTakeReachesTheProxyWhereTheLiveMonitorPutIt() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let white = try await proxyWhite(transfer: .hlg, root: root)
        let monitor = try Self.onTheMonitor(HDRTransfer.referenceWhiteNits,
                                            transfer: .hlg)
        let untouched = try Self.leftAlone(HDRTransfer.referenceWhiteNits,
                                           transfer: .hlg)
        #expect(abs(white - Double(monitor)) <= 4,
                "HLG diffuse white reached the proxy at \(white), monitor \(monitor)")
        #expect(white - Double(untouched) > 40,
                "HLG diffuse white is still near the untone-mapped \(untouched): \(white)")
    }

    /// What the proxy now SAYS about itself. Its codes went through a Rec.709
    /// curve on the way in, so it states one — a file that still claimed PQ
    /// would be crushed a second time by every player that believed it. The
    /// primaries are deliberately NOT converted and it states Rec.2020,
    /// because that is literally what the codes are: a per-channel tone map
    /// cannot move a primary.
    @Test func theProxyStatesTheCurveItsCodesAreNowOn() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeHDRTake(
            at: root.appendingPathComponent("hdr.mov"), transfer: .pq,
            nits: HDRTransfer.referenceWhiteNits, width: 320, height: 180,
            frames: 6)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the HDR take produced no daily")
        let asset = AVURLAsset(url: daily)
        let track = try #require(try await asset.tracks(ofType: .video).first,
                                 "the daily has no video track")
        let description: CMFormatDescription = try #require(
            try await track.load(.formatDescriptions).first,
            "the daily's video track has no format description")
        let colorimetry = ColorTags.colorimetry(of: description)
        #expect(colorimetry.transfer == .sdr,
                "the proxy still claims \(colorimetry.transfer) after tone mapping")
        #expect(colorimetry.primaries == .rec2020,
                "the proxy claims \(colorimetry.primaries), not the camera's")
    }

    /// The order trap, made a measurement. The lookup is the PICTURE's, so a
    /// burn-in's own white survives it — and its semi-transparent plate reads
    /// as a fixed fraction of the FINISHED picture beside it. Run the lookup
    /// after the overlay instead and the plate reads the fraction of a picture
    /// that had not been tone mapped yet, put through the map afterwards,
    /// which is a different and much darker number.
    @Test func theBurnInsAreCompositedOntoTheFinishedPicture() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeHDRTake(
            at: root.appendingPathComponent("hdr.mov"), transfer: .pq,
            nits: HDRTransfer.referenceWhiteNits,
            width: Int(Self.raster.width), height: Int(Self.raster.height))
        let fixture = DailiesRig.item(for: source)
        let report = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.allBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the HDR take produced no daily")
        let frame = try await DailiesRig.decodeFrame(0, of: daily)
        let overlay = DailiesOverlay(
            size: Self.raster,
            texts: DailiesRig.allBurnins.overlayTexts(for: fixture))
        let strip = try #require(overlay.layout.timecode,
                                 "the timecode strip was not laid out")

        // the overlay's own white is still the overlay's own white
        let white = DailiesRig.peakLevel(frame, in: strip)
        #expect(white >= 250,
                "the burn-in white came out at \(white) instead of the overlay's 255")

        // and its plate is that fraction of the picture it sits on
        let picture = DailiesRig.meanLevel(
            frame, in: DailiesRig.centerRegion(of: Self.raster))
        let plate = DailiesRig.meanLevel(
            frame, in: DailiesRig.plateRegion(of: strip))
        let expected = picture * DailiesRig.plateTransmission
        #expect(abs(plate - expected) <= 10,
                "the plate reads \(plate) over a picture of \(picture), not \(expected)")
    }

    /// An SDR take is what it was, and the claim is bit for bit rather than
    /// close enough: `StudioSwing.playbackTable` answers nil for a plain SDR
    /// file, so the composer hands the decoded frame straight back — the same
    /// buffer, the same bytes — and the encode settings gain no colour
    /// properties key they did not have.
    @Test func anSDRTakeIsUntouchedByAllOfThis() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("sdr.mov"), frames: 10, level: 128)
        let fixture = DailiesRig.item(for: source)
        let facts = try await DailiesSourceFacts.probe(
            item: fixture, burnins: DailiesRig.noBurnins)

        // The table itself never goes into an expectation: it is 256 entries
        // and a failure would render every one of them.
        let levelled: Bool = facts.levels != nil
        #expect(!levelled, "a plain SDR take picked up a levels table")
        #expect(facts.colorimetry == .sdr,
                "a plain SDR take read back as \(facts.colorimetry)")
        let settings: [String: Any] = DailiesEngine.videoSettings(
            size: facts.outputSize, frameRate: 25,
            colorimetry: facts.colorimetry)
        #expect(settings[AVVideoColorPropertiesKey] == nil,
                "an SDR daily gained colour properties it never had")

        let composer = DailiesFrameComposer(item: fixture,
                                            burnins: DailiesRig.noBurnins,
                                            facts: facts)
        let frame = Self.rampBuffer(width: 320, height: 180)
        let before: [UInt8] = Self.bytes(of: frame)
        let composed: CVPixelBuffer = try composer.compose(frame, pts: .zero)
        #expect(composed === frame, "the composer copied a frame it need not have")
        let changed: Int = Self.differingBytes(before, Self.bytes(of: composed))
        #expect(changed == 0,
                "the composer changed \(changed) bytes of an SDR frame")

        // …and end to end, the grey the take was written at is the grey the
        // daily comes out at
        let report = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the SDR take produced no daily")
        let decoded = try await DailiesRig.decodeFrame(0, of: daily)
        let level = DailiesRig.meanLevel(
            decoded, in: DailiesRig.centerRegion(of: CGSize(width: 320,
                                                            height: 180)))
        #expect(abs(level - 128) <= 4, "an SDR daily's grey moved to \(level)")
    }

    /// The OTHER half of the same lookup, and the reason it is one lookup: an
    /// RGB take carries studio-swing codes and says so with its levels key, so
    /// its daily needs the swing expansion whether or not there is a curve to
    /// tone map as well. Forgetting it would put nominal black 6 % up the scale
    /// in every proxy of an RGB take, which is the complaint the display table
    /// exists to answer.
    @Test func anRGBTakesSwingIsExpandedIntoTheProxyToo() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("rgb.mov"), frames: 10, level: 200,
            wireCodes: true)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the RGB take produced no daily")
        let frame = try await DailiesRig.decodeFrame(0, of: daily)
        let level = DailiesRig.meanLevel(
            frame, in: DailiesRig.centerRegion(of: CGSize(width: 320,
                                                          height: 180)))
        let expanded = Int(StudioSwing.expansionTable[200])
        #expect(abs(level - Double(expanded)) <= 4,
                "the RGB take's 200 reached the proxy at \(level), expanded is \(expanded)")
        #expect(level - 200 > 8,
                "the RGB take's swing was never expanded: \(level) is still 200")
    }

    /// A clip this app did not write says nothing about its levels and nothing
    /// about its curve, and it is left exactly as it is — the same answer the
    /// player reaches for the same file. Guessing here would crush a foreign
    /// clip's shadows on the strength of a tag that is not there.
    @Test func aForeignOrUntaggedClipIsLeftAlone() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeForeignClip(
            at: root.appendingPathComponent("foreign.mp4"), level: 128)
        let fixture = DailiesRig.item(for: source)
        let facts = try await DailiesSourceFacts.probe(
            item: fixture, burnins: DailiesRig.noBurnins)
        let levelled: Bool = facts.levels != nil
        #expect(!levelled, "a foreign clip picked up a levels table")
        #expect(facts.colorimetry == .sdr,
                "a foreign clip read back as \(facts.colorimetry)")

        let report = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output,
                                 "the foreign clip produced no daily")
        let frame = try await DailiesRig.decodeFrame(0, of: daily)
        let level = DailiesRig.meanLevel(
            frame, in: DailiesRig.centerRegion(of: CGSize(width: 320,
                                                          height: 180)))
        #expect(abs(level - 128) <= 4, "a foreign clip's grey moved to \(level)")
    }

    // MARK: - byte-level helpers

    /// A BGRA frame whose every pixel is a different code, so ANY table
    /// lookup over it changes bytes.
    private static func rampBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return buffer
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes + y * row + x * 4
                pixel[0] = UInt8((x * 7 + y) % 256)
                pixel[1] = UInt8((x + y * 3) % 256)
                pixel[2] = UInt8((x * 251 + y * 13) % 256)
                pixel[3] = 0xFF
            }
        }
        return buffer
    }

    private static func bytes(of buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        return [UInt8](UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: CVPixelBufferGetBytesPerRow(buffer)
                * CVPixelBufferGetHeight(buffer)))
    }

    private static func differingBytes(_ first: [UInt8],
                                       _ second: [UInt8]) -> Int {
        guard first.count == second.count else { return first.count }
        return zip(first, second).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
