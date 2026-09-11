import CoreGraphics
import Testing

@testable import TakeShotKit

/// **A histogram's height is its COUNT** (owner, holding ours next to
/// Resolve's: "мне кажется у нас гистограмма не оч верная").
///
/// It was logarithmic, which is why every ordinary picture came out as a
/// plateau: the shape an operator reads a histogram for had been squeezed into
/// the top eighth of the row. The numbers below are what that cost, and they
/// are the reason this is a function with a test rather than a line inside a
/// path builder.
@Suite struct ViewHistogramScaleTests {
    private let row: CGFloat = 100

    /// Half the count is half the height, a tenth is a tenth. Under the log
    /// scale those two were 91 and 72 points of the same hundred.
    @Test func theHeightIsProportionalToTheCount() {
        let peak = 1000
        #expect(ScopeHistogramScale.height(count: peak, peak: peak,
                                           rowHeight: row) == 100)
        #expect(ScopeHistogramScale.height(count: 500, peak: peak,
                                           rowHeight: row) == 50)
        #expect(ScopeHistogramScale.height(count: 100, peak: peak,
                                           rowHeight: row) == 10)
        #expect(ScopeHistogramScale.height(count: 10, peak: peak,
                                           rowHeight: row) == 1)
    }

    /// An empty bin draws nothing at all — the baseline is the picture having
    /// none of that tone, and a floor under it would be ink claiming a code
    /// the frame does not contain.
    @Test func anEmptyBinDrawsNothing() {
        #expect(ScopeHistogramScale.height(count: 0, peak: 1000,
                                           rowHeight: row) == 0)
    }

    /// Degenerate inputs answer zero rather than dividing: a series with no
    /// samples in it at all is a row with nothing to draw.
    @Test func aSeriesWithNoSamplesDrawsNothing() {
        #expect(ScopeHistogramScale.height(count: 5, peak: 0,
                                           rowHeight: row) == 0)
        #expect(ScopeHistogramScale.height(count: 5, peak: 10,
                                           rowHeight: 0) == 0)
    }

    /// A bin taller than the peak it was given cannot leave the row — the two
    /// come from one series, so it means the caller passed a stale peak, and a
    /// path that runs off the top of its box is a drawing bug in the making.
    @Test func aBinCannotDrawPastTheTopOfItsRow() {
        #expect(ScopeHistogramScale.height(count: 4000, peak: 1000,
                                           rowHeight: row) == 100)
    }
}
