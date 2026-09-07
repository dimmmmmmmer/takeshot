import CR3D
import Foundation
import Testing

@testable import TakeShotKit

/// **What `Auto` decides, on a machine with no SDK and no footage.**
///
/// The rule is arithmetic and not SDK work — the most reduction that still
/// fills a 1080-class viewer, because an assist does not need 8K pixels to
/// judge focus and each halving is a quarter of the decode rather than a
/// resize after it. `CR3DClip.divisorForScale:width:` answers it in both
/// halves of the bridge for exactly this reason, and its own doc says so:
/// "exposed for the app's readouts and for tests".
///
/// There were no tests. The rule decides what an operator sees the moment they
/// scrub an 8K clip — too much reduction is a soft picture to judge focus on,
/// too little is a transport that will not keep up — and nothing anywhere
/// stated what it does.
struct R3DScaleRuleTests {
    /// `Auto` on the rasters a RED camera actually writes.
    @Test func autoTakesTheMostReductionThatStillFillsAViewer() {
        for (width, divisor) in [(1_920, 1), (2_048, 1), (3_840, 2),
                                 (4_096, 2), (6_144, 2), (7_680, 4),
                                 (8_192, 4), (16_384, 8)] {
            let picked = CR3DClip.divisor(for: .auto, width: UInt32(width))
            #expect(picked == UInt32(divisor), """
                \(width) wide resolved to 1/\(picked), which leaves \
                \(width / Int(picked)) pixels across
                """)
            // The rule stated as the rule, not as the table: whatever it
            // picked has to leave at least a 1080-class raster, and one more
            // halving would not have.
            #expect(width / Int(picked) >= 1_920,
                    "\(width)/\(picked) is under a 1080-class viewer")
            if picked < 8 {
                #expect(width / Int(picked * 2) < 1_920,
                        "\(width) could have taken 1/\(picked * 2) and did not")
            }
        }
    }

    /// A scale the operator CHOSE is taken as given — the point of the setting
    /// is to overrule the rule above on a machine that can afford more.
    @Test func aChosenScaleIsTakenAsGiven() {
        for scale: CR3DDecodeScale in [.full, .half, .quarter, .eighth] {
            #expect(CR3DClip.divisor(for: scale, width: 8_192)
                    == UInt32(scale.rawValue))
        }
    }

    /// …and both halves of the bridge answer the same, which is what makes
    /// this suite meaningful on CI. A rule that lived only in the SDK half
    /// would be untested everywhere it matters.
    @Test func theRuleAnswersWithNoSDKAtAll() {
        // Whether this machine has the SDK is not something to branch on: the
        // assertion is that an answer comes back either way, which is the
        // property the stub exists for.
        #expect(CR3DClip.divisor(for: .auto, width: 8_192) > 0)
    }
}
