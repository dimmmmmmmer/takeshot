import Foundation
import Testing

@testable import CaptureCore

/// **A legend on a side edge puts its scale against that edge.**
///
/// The column was drawn at the panel's left whichever side the legend sat on,
/// so a legend placed RIGHT had its numbers against the bezel and its swatches
/// pushed inward — the plate reading as if it took extra room off one border
/// (owner: "легенды фалс колора и эл зона если стоят по бокам их подложка
/// подзабирает лишнее пространство либо с левого либо с правого борта").
@Suite struct AssistLegendSideTests {
    private var metrics: AssistLegendMetrics {
        AssistLegendSize.medium.metrics
    }

    /// On the left the scale is at the panel's left, which it always was.
    @Test func aLeftLegendKeepsItsScaleOnTheLeft() {
        let panelWidth: CGFloat = 200
        let columns = AssistLegend.columnLayout(mirrored: false,
                                                metrics: metrics,
                                                panelWidth: panelWidth)
        #expect(columns.swatch == metrics.padding)
        #expect(columns.label > columns.swatch,
                "the numbers are not inboard of the scale")
    }

    /// On the right it is mirrored: the two side placements are each other's
    /// reflection.
    @Test func aRightLegendPutsItsScaleAgainstTheRightEdge() {
        let panelWidth: CGFloat = 200
        let columns = AssistLegend.columnLayout(mirrored: true,
                                                metrics: metrics,
                                                panelWidth: panelWidth)
        #expect(columns.swatch + metrics.swatchThickness
            == panelWidth - metrics.padding,
                "the scale is \(columns.swatch), not against the edge")
        #expect(columns.label < columns.swatch,
                "the numbers are not inboard of the scale")
    }

    /// The two are the same distance from their own edge — which is the
    /// property the complaint was about, and it is one subtraction to check.
    @Test func bothSidesLeaveTheSameMarginAgainstTheirEdge() {
        let panelWidth: CGFloat = 200
        let left = AssistLegend.columnLayout(mirrored: false, metrics: metrics,
                                             panelWidth: panelWidth)
        let right = AssistLegend.columnLayout(mirrored: true, metrics: metrics,
                                              panelWidth: panelWidth)
        let leftGap = left.swatch
        let rightGap = panelWidth - (right.swatch + metrics.swatchThickness)
        #expect(leftGap == rightGap,
                "left leaves \(leftGap)pt and right \(rightGap)pt")
    }

    /// …and nothing runs outside the plate on either side.
    @Test func neitherColumnEscapesThePanel() {
        let panelWidth: CGFloat = 200
        for mirrored in [false, true] {
            let columns = AssistLegend.columnLayout(
                mirrored: mirrored, metrics: metrics, panelWidth: panelWidth)
            #expect(columns.swatch >= 0)
            #expect(columns.label >= 0,
                    "the labels start at \(columns.label)")
            #expect(columns.swatch + metrics.swatchThickness <= panelWidth)
            #expect(columns.label + metrics.labelWidth <= panelWidth,
                    "the labels end at \(columns.label + metrics.labelWidth) of \(panelWidth)")
        }
    }

    /// The panel is the same size on both sides — the mirroring moves what is
    /// inside it and must not change what it takes off the picture.
    @Test func theSideLegendsAreTheSameSize() throws {
        let frame = CGSize(width: 1920, height: 1080)
        let left = AssistLegend(size: .medium, placement: .left)
        let right = AssistLegend(size: .medium, placement: .right)
        let leftLayout = try #require(left.layout(for: .falseColor, in: frame))
        let rightLayout = try #require(right.layout(for: .falseColor, in: frame))
        #expect(leftLayout.rect.size == rightLayout.rect.size)
        // …and each is the same distance from its own edge.
        #expect(leftLayout.rect.minX
            == frame.width - rightLayout.rect.maxX,
                "left at \(leftLayout.rect.minX), right at \(frame.width - rightLayout.rect.maxX)")
    }
}
