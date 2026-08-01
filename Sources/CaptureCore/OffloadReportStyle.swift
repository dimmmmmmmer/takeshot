import CoreGraphics
import CoreText
import Foundation

// The offload report card's visual language: every measurement, every colour
// and the one description of how a piece of text is set.
//
// Split out of `OffloadReportCard` so the drawing reads as drawing. A section
// that says "banner, then 26 points of air" belongs next to the other sections;
// the 26 belongs here, with the other numbers, where a change to the rhythm of
// the card is one edit rather than a hunt through the paint.

/// Every number the card is laid out from, in points and in one place.
enum CardMetrics {
    static let margin: CGFloat = 40
    static let maxProblemLines = 6

    static let brandSize: CGFloat = 12
    static let headlineSize: CGFloat = 30
    static let verdictSize: CGFloat = 16
    static let pathSize: CGFloat = 13
    static let labelSize: CGFloat = 11
    static let valueSize: CGFloat = 20
    static let bodySize: CGFloat = 13

    /// Height of each block, and the air after it.
    static let brandBlock: CGFloat = 22
    static let headlineBlock: CGFloat = 40
    static let pathBlock: CGFloat = 24
    static let bannerHeight: CGFloat = 56
    static let bannerRadius: CGFloat = 10
    static let bannerTextInset: CGFloat = 20
    static let statLabelBlock: CGFloat = 18
    static let statValueBlock: CGFloat = 28
    static let problemsHeadBlock: CGFloat = 26
    static let footerRuleBlock: CGFloat = 14
    static let lineHeight: CGFloat = 20
    static let gap: CGFloat = 22
    static let statColumns = 4
    /// Width of the label column in the source/started/finished rows.
    static let factLabelWidth: CGFloat = 90

    /// Content width — what a line of text has to fit into.
    static var textWidth: CGFloat { OffloadReportCard.width - 2 * margin }

    /// Height of the whole card. Everything above the problem list is fixed, so
    /// the only variable is how many lines that list has.
    static func height(problemLines: Int) -> CGFloat {
        let fixed = margin
            + brandBlock + headlineBlock + pathBlock + 12
            + bannerHeight + 26
            + statLabelBlock + statValueBlock + gap
            + 3 * lineHeight + gap
            + footerRuleBlock + 16
            + margin
        guard problemLines > 0 else { return fixed }
        return fixed + problemsHeadBlock + CGFloat(problemLines) * lineHeight + 10
    }
}

/// Ink. Computed rather than stored because a `CGColor` is not Sendable, and a
/// `static let` of one is a concurrency error in Swift 6 language mode — which
/// CaptureCore is compiled in.
///
/// One palette, dark, whatever theme the app is in. The card is not a screenshot
/// of this Mac — it is a file that outlives the session and gets looked at on
/// somebody else's phone, so it cannot depend on a preference that is not
/// written into it. Dark is the app's own resting state and the one a set
/// monitor is calibrated for; a report that arrived light one day and dark the
/// next would read as two different tools' output.
enum CardInk {
    static var background: CGColor { gray(0.075) }
    static var primary: CGColor { gray(0.96) }
    static var secondary: CGColor { gray(0.60) }
    static var rule: CGColor { gray(0.22) }

    /// The same three colours the result card uses on screen, so the picture and
    /// the sheet cannot disagree about how bad the news is.
    static func verdict(_ outcome: OffloadOutcome) -> CGColor {
        switch outcome {
        case .verified:
            return CGColor(srgbRed: 0.22, green: 0.74, blue: 0.38, alpha: 1)
        case .mismatched, .cancelled:
            return CGColor(srgbRed: 0.98, green: 0.62, blue: 0.15, alpha: 1)
        case .failed:
            return CGColor(srgbRed: 0.94, green: 0.28, blue: 0.22, alpha: 1)
        }
    }

    /// The plate a verdict sits on: its own colour, most of the way out of the
    /// way. Matches the sheet's `color.opacity(0.08)` card, allowing for the
    /// darker ground this is drawn on.
    static func plate(_ tint: CGColor) -> CGColor {
        tint.copy(alpha: 0.16) ?? tint
    }

    private static func gray(_ value: CGFloat) -> CGColor {
        CGColor(srgbRed: value, green: value, blue: value, alpha: 1)
    }
}

/// How one piece of text is set. A value rather than three more arguments on
/// every draw call — which is also what keeps the drawing code readable as a
/// list of what is on the card rather than how it is typeset.
struct CardTextStyle {
    var size: CGFloat
    var bold = false
    var color: CGColor

    /// The system UI font, which is what the app itself is set in. The fallback
    /// is never expected to be reached; a report that silently rendered nothing
    /// because a font lookup returned nil would be the worse failure.
    var font: CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system,
                                      size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}
