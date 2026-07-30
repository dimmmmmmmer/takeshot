import CoreGraphics
import Foundation

/// Where a level sits on a meter, 0 at the bottom and 1 at the top.
///
/// The small footer meter and the big channel panel are two drawings of one
/// measurement, and each had its own copy of this. Two mappings of dBFS to
/// height is two meters that can disagree about what -6 looks like, which is
/// the one thing a meter exists to answer.
enum AudioMeterScale {
    static func fraction(of level: Float,
                         in range: ClosedRange<Float>) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound)
                       / (range.upperBound - range.lowerBound))
    }
}
