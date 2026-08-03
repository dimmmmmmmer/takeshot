import CaptureCore

// What the assist popover calls the legend's size and its edge. The values
// themselves are `AssistLegendSize` / `AssistLegendPlacement` in CaptureCore,
// where the legend is drawn; only the localization keys are the app layer's
// business, and they live here for the same reason
// `ViewAssist.PeakingColor.labelKey` does — a `.strings` key has no place in a
// renderer.
//
// This file used to BE the legend: a SwiftUI overlay over the player, sized and
// inset to dodge the badge row and the transport. It is not a view any more.
// An overlay reaches the surface it is mounted on and nothing else, so the
// legend was on the operator's window while the director's monitor and the
// hardware playout showed nine flat colours with no key to them — the same
// fault the framelines had (owner item 7), and the owner ruled the same way on
// it: burn it in. It is drawn into the display frame now (`AssistLegend` in
// CaptureCore), which is what every mirror of the viewer is fed, and the two
// legends that would otherwise be on screen at once are one.

extension AssistLegendSize {
    var labelKey: String { "legend_size_" + rawValue }
}

extension AssistLegendPlacement {
    var labelKey: String { "legend_" + rawValue }
}
