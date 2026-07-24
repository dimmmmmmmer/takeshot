import Foundation

/// SMPTE timecode. `fps` is the nominal frame-numbering rate (24, 25, 30, 60...);
/// for 29.97/59.94 drop-frame use `fps` 30/60 + `isDropFrame`.
public struct Timecode: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var fps: Int
    public var isDropFrame: Bool

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, fps: Int, isDropFrame: Bool = false) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.fps = fps
        self.isDropFrame = isDropFrame
    }

    /// The real frame ordinal since midnight (accounts for drop-frame), i.e. two
    /// consecutive recorded frames always differ by exactly 1 — including across
    /// a DF minute boundary.
    public var frameNumber: Int {
        let nominal = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        guard isDropFrame, fps % 30 == 0 else { return nominal }
        let dropPerMinute = fps / 15 // 2 for 30, 4 for 60
        let totalMinutes = hours * 60 + minutes
        return nominal - dropPerMinute * (totalMinutes - totalMinutes / 10)
    }

    /// Inverse transform: real frame number → a timecode label.
    /// Parse "HH:MM:SS:FF" (";" before FF for drop-frame). nil on junk.
    public init?(text: String, fps: Int) {
        let dropFrame = text.contains(";")
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" })
            .compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        self.init(hours: parts[0], minutes: parts[1], seconds: parts[2],
                  frames: parts[3], fps: max(1, fps), isDropFrame: dropFrame)
    }

    public init(frameNumber: Int, fps: Int, isDropFrame: Bool = false) {
        var fn = max(0, frameNumber)
        if isDropFrame, fps % 30 == 0 {
            let dropPerMinute = fps / 15
            let framesPerMinute = fps * 60 - dropPerMinute        // every minute except each 10th
            let framesPer10Minutes = fps * 600 - dropPerMinute * 9
            let tenMinuteBlocks = fn / framesPer10Minutes
            let rem = fn % framesPer10Minutes
            if rem > dropPerMinute {
                fn += dropPerMinute * 9 * tenMinuteBlocks
                    + dropPerMinute * ((rem - dropPerMinute) / framesPerMinute)
            } else {
                fn += dropPerMinute * 9 * tenMinuteBlocks
            }
        }
        self.frames = fn % fps
        fn /= fps
        self.seconds = fn % 60
        fn /= 60
        self.minutes = fn % 60
        self.hours = (fn / 60) % 24
        self.fps = fps
        self.isDropFrame = isDropFrame
    }

    public func advanced(by n: Int) -> Timecode {
        Timecode(frameNumber: frameNumber + n, fps: fps, isDropFrame: isDropFrame)
    }

    public var description: String {
        let sep = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// A filename-safe variant (no colons).
    public var fileNameSafe: String {
        String(format: "%02d.%02d.%02d.%02d", hours, minutes, seconds, frames)
    }
}
