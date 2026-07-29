import SwiftUI
import Testing
@testable import TakeShotKit

/// The player backdrop, the window background and the accent are persisted as
/// "#RRGGBB" strings in CaptureSettings and read back through this pair. The
/// round trip has to be exact: it runs on every settings save, so a one-code
/// drift would walk the operator's chosen colour across the day, and a parser
/// that accepts junk would write a colour nobody picked.
struct ModelColorHexTests {
    @Test func parsesSixDigitHexWithAndWithoutHash() {
        #expect(Color(hex: "#FF0000")?.hexString == "#FF0000")
        #expect(Color(hex: "00FF00")?.hexString == "#00FF00")
        // lowercase is what a hand-edited settings file usually contains
        #expect(Color(hex: "#0000ff")?.hexString == "#0000FF")
        // surrounding whitespace survives a copy-paste into the field
        #expect(Color(hex: "  #123456  ")?.hexString == "#123456")
    }

    @Test func roundTripIsExactAndIdempotent() {
        for hex in ["#000000", "#FFFFFF", "#808080", "#1E2A3B", "#FF7F00",
                    "#010203", "#FEFDFC"] {
            let once = Color(hex: hex)?.hexString
            #expect(once == hex, "\(hex) came back as \(once ?? "nil")")
            // a second save/load cycle must not move it either
            #expect(Color(hex: once ?? "")?.hexString == hex)
        }
    }

    @Test func rejectsAnythingThatIsNotSixHexDigits() {
        #expect(Color(hex: "") == nil)
        #expect(Color(hex: "#") == nil)
        #expect(Color(hex: "#FFF") == nil)          // 3-digit shorthand is not supported
        #expect(Color(hex: "#FF00000") == nil)      // seven digits
        #expect(Color(hex: "#GGGGGG") == nil)
        #expect(Color(hex: "#12345Z") == nil)
        #expect(Color(hex: "red") == nil)
        #expect(Color(hex: "#FF0000FF") == nil)     // RGBA is not this format
        // UInt32(_:radix:) takes a sign, so these used to parse as colours
        #expect(Color(hex: "+FF000") == nil)
        #expect(Color(hex: "-FF000") == nil)
    }

    /// The channel order is the one thing a hex parser gets wrong silently:
    /// swapped R and B still round-trips through itself.
    @Test func channelOrderIsRedGreenBlue() {
        #expect(Color(hex: "#FF0000")?.hexString == "#FF0000")
        #expect(Color(hex: "#00FF00")?.hexString == "#00FF00")
        #expect(Color(hex: "#0000FF")?.hexString == "#0000FF")
        // an asymmetric value pins all three at once
        #expect(Color(hex: "#102040")?.hexString == "#102040")
    }
}
