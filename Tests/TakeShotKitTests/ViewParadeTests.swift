import CaptureCore
import CoreVideo
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The parade is YRGB** (owner: "сделай парады yrgb").
///
/// Two assertions, because either alone is half an answer: the columns are the
/// four they claim to be, and four of them really reach the screen.
@Suite @MainActor struct ViewParadeTests {
    /// A flat mid-grey field: every one of the four traces lands at the same
    /// height, so a horizontal band across the middle crosses all of them and
    /// the gaps between the columns are what is left.
    private static func flatFieldData() throws -> ScopeData {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<180 {
                let line = bytes + row * rowBytes
                for column in 0..<320 {
                    line[column * 4] = 128
                    line[column * 4 + 1] = 128
                    line[column * 4 + 2] = 128
                    line[column * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return try #require(ScopeAnalyzer.analyze(buffer))
    }

    /// The order, as a value: Y first, then the three channels.
    @Test func theColumnsAreLumaThenTheThreeChannels() {
        #expect(ParadeView.columns.map(\.map)
            == [.lumaColor, .red, .green, .blue], """
            the parade's columns are \(ParadeView.columns.map(\.map)) — the \
            luma column is what makes it a YRGB parade
            """)
        #expect(ParadeView.columns.first?.tint == nil, """
            the luma column is tinted — that map already carries the image's \
            own colours
            """)
    }

    /// …and four columns are drawn. A flat field puts one trace across the
    /// whole width of each column, so counting the RUNS of ink across the
    /// middle counts the columns — three with the parade this replaces.
    @Test func fourColumnsReachTheScreen() async throws {
        let data = try Self.flatFieldData()
        try await ViewProbe.run { probe in
            let box = CGSize(width: 480, height: 300)
            let lit = ViewRender.brightColumns(
                probe.hosted(ParadeView(data: data)
                    .environment(\.scopeGridBrightness, 0.0001)
                    .background(Color.black)),
                in: box, rows: 0.35...0.65, threshold: 30)
            var runs = 0
            var previous = -10
            for column in lit {
                if column > previous + 1 { runs += 1 }
                previous = column
            }
            #expect(runs == 4, """
                the parade drew \(runs) column(s) of trace (\(lit.count) lit \
                columns) — a YRGB parade is four
                """)
        }
    }
}
