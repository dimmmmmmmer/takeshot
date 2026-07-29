import AppKit
import SwiftUI

extension Color {
    /// "#RRGGBB" → Color; an invalid string — nil.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        // `UInt32(_:radix:)` accepts a leading sign, so "+FF000" parses as
        // 0x0FF000 and a malformed colour silently becomes a valid one.
        guard value.count == 6, value.allSatisfy(\.isHexDigit),
              let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}
