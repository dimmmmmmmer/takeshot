import Foundation

/// A channel bit mask as an operator reads it: "1-2", "1, 2, 5-8".
///
/// One-based, because the meters are numbered from 1 on the panel and on every
/// sound report, while the mask's bit 0 is channel 1 — a status line that
/// disagreed with the column heading directly above it would be worse than no
/// status line.
///
/// Runs collapse to a range because the masks this actually prints are runs:
/// a stereo embed is 1-2 and an eight-channel cart is 1-8, and "1, 2, 3, 4, 5,
/// 6, 7, 8" is a number nobody reads, it is a length they estimate.
enum AudioChannelList {
    /// The channels set in `mask`, up to `count` of them — 16 when the source
    /// has not said, which is what the DeckLink bridge declares.
    ///
    /// Capped at what the SOURCE carries so the line cannot name a channel the
    /// meters do not show: a mask is stored as 16 bits wide whatever arrives,
    /// and a two-channel USB cart with a stale 1-8 mask would otherwise be
    /// described in channels that do not exist.
    static func describe(_ mask: Int, upTo count: Int) -> String {
        let width = count > 0 ? min(count, 32) : 16
        let channels: [Int] = (0..<width).filter { mask & (1 << $0) != 0 }
        guard !channels.isEmpty else { return "" }
        var parts: [String] = []
        var start = channels[0]
        var previous = start
        for channel in channels.dropFirst() {
            if channel == previous + 1 {
                previous = channel
                continue
            }
            parts.append(Self.run(from: start, to: previous))
            start = channel
            previous = channel
        }
        parts.append(Self.run(from: start, to: previous))
        return parts.joined(separator: ", ")
    }

    /// One run, one-based. A run of one is a number, not a range of itself.
    private static func run(from start: Int, to end: Int) -> String {
        start == end ? "\(start + 1)" : "\(start + 1)-\(end + 1)"
    }
}
