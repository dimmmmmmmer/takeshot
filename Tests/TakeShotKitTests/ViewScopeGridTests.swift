import CoreGraphics
import Testing

@testable import TakeShotKit

/// The scopes window's grid. The owner asked it to "стремиться к тому чтобы
/// квадратную 2x2 сетку из скопов собирать" — and the rule it replaced could
/// not, because it packed as many fixed-width columns as fit and so laid four
/// scopes out in one row the moment the window was wide.
struct ViewScopeGridTests {
    private let wide = CGSize(width: 1600, height: 900)
    private let laptop = CGSize(width: 1100, height: 700)
    private let tall = CGSize(width: 700, height: 1200)

    /// The case the change exists for: four scopes, a wide window, 2×2 — where
    /// "as many as fit" gave four columns of 400×900 slivers.
    @Test func fourScopesMakeASquareGridOnAWideWindow() {
        #expect(ScopeGridLayout.columns(for: 4, in: wide) == 2)
        #expect(ScopeGridLayout.columns(for: 4, in: laptop) == 2)
    }

    /// And it stays 2×2 when the window is turned on its side: a column of four
    /// is as wrong as a row of four.
    @Test func fourScopesStaySquareOnATallWindow() {
        #expect(ScopeGridLayout.columns(for: 4, in: tall) == 2)
    }

    /// Two scopes sit side by side while there is width for it, and stack when
    /// the window is a portrait.
    @Test func twoScopesFollowTheWindowsShape() {
        #expect(ScopeGridLayout.columns(for: 2, in: wide) == 2)
        #expect(ScopeGridLayout.columns(for: 2, in: tall) == 1)
    }

    /// One scope is one column, whatever the window is doing.
    @Test func oneScopeIsOneColumn() {
        for size in [wide, laptop, tall, CGSize(width: 300, height: 200)] {
            #expect(ScopeGridLayout.columns(for: 1, in: size) == 1)
        }
    }

    /// Readability outranks shape: in a narrow window the boxes stack rather
    /// than shrink under what a trace needs to be legible at all.
    @Test func aNarrowWindowStacksRatherThanShrinks() {
        let narrow = CGSize(width: 420, height: 900)
        #expect(ScopeGridLayout.columns(for: 4, in: narrow) == 1)
        let box = narrow.width / CGFloat(ScopeGridLayout.columns(for: 4, in: narrow))
        #expect(box >= ScopeGridLayout.minimumBoxWidth)
    }

    /// A degenerate size arrives during window setup, before layout has run.
    @Test func aZeroSizedWindowStillAsksForAColumn() {
        #expect(ScopeGridLayout.columns(for: 4, in: .zero) == 1)
        #expect(ScopeGridLayout.columns(for: 0, in: wide) == 1)
    }

    /// Five scopes — which is what adding CIE chromaticity will make — cannot
    /// be square, and the grid should not pretend: three and two beats a row of
    /// five or a 4+1 with a hole in the middle of the window.
    @Test func fiveScopesTakeTheLeastRaggedGrid() {
        #expect(ScopeGridLayout.columns(for: 5, in: wide) == 3)
    }
}
