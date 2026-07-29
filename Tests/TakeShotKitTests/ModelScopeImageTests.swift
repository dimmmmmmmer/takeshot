import CaptureCore
import CoreGraphics
import Foundation
import Testing
@testable import TakeShotKit

/// The scope views hand raw analyzer bytes straight to `CGImage`, which does not
/// validate the buffer against the geometry it is told: a byte count that does
/// not match `width * height` is read past the end. The length guard here is the
/// only thing standing between an analyzer whose resolution changed and a read
/// of unmapped memory in the scopes panel.
struct ModelScopeImageTests {
    private func bytes(_ count: Int, fill: UInt8 = 0x40) -> [UInt8] {
        [UInt8](repeating: fill, count: count)
    }

    @Test func grayscaleImageMatchesTheRequestedGeometry() throws {
        let image = try #require(grayscaleImage(
            from: bytes(ScopeData.waveWidth * ScopeData.waveHeight)))
        #expect(image.width == ScopeData.waveWidth)
        #expect(image.height == ScopeData.waveHeight)
        #expect(image.bitsPerPixel == 8)
        #expect(image.bytesPerRow == ScopeData.waveWidth)
    }

    @Test func rgbaImageMatchesTheRequestedGeometry() throws {
        let image = try #require(rgbaImage(
            from: bytes(ScopeData.waveWidth * ScopeData.waveHeight * 4)))
        #expect(image.width == ScopeData.waveWidth)
        #expect(image.height == ScopeData.waveHeight)
        #expect(image.bitsPerPixel == 32)
        #expect(image.bytesPerRow == ScopeData.waveWidth * 4)
    }

    /// Short, long and empty buffers must all be refused rather than trusted.
    @Test func aByteCountThatDoesNotMatchTheGeometryIsRefused() {
        let expected = ScopeData.waveWidth * ScopeData.waveHeight
        #expect(grayscaleImage(from: []) == nil)
        #expect(grayscaleImage(from: bytes(expected - 1)) == nil)
        #expect(grayscaleImage(from: bytes(expected + 1)) == nil)
        // the RGBA-sized buffer is not a valid grayscale map either
        #expect(grayscaleImage(from: bytes(expected * 4)) == nil)

        #expect(rgbaImage(from: []) == nil)
        #expect(rgbaImage(from: bytes(expected)) == nil)
        #expect(rgbaImage(from: bytes(expected * 4 - 1)) == nil)
    }

    /// The vectorscope is square and smaller than the waveform, so the explicit
    /// size arguments have to be honoured rather than the defaults reused.
    @Test func explicitGeometryOverridesTheWaveformDefaults() throws {
        let size = ScopeData.vectorSize
        let image = try #require(grayscaleImage(from: bytes(size * size),
                                                width: size, height: size))
        #expect(image.width == size && image.height == size)
        // …and the length guard follows the override, not the default
        #expect(grayscaleImage(from: bytes(size * size),
                               width: ScopeData.waveWidth,
                               height: ScopeData.waveHeight) == nil)
    }
}
