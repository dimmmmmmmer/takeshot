import Foundation

/// Operator display aids applied inside the preview render (identically on
/// every surface: live, playback, RAW, fullscreen, external).
public struct ViewAssist: Equatable, Sendable {
    /// Color remap tools are mutually exclusive; zebra/peaking stack on top.
    public enum ColorTool: String, CaseIterable, Sendable {
        case off
        case falseColor
        case elZone
    }

    public var colorTool: ColorTool = .off
    public var zebraOn = false
    /// Zebra trigger level, 0.70…1.0 of full scale.
    public var zebraThreshold: Double = 0.95
    public var peakingOn = false
    /// Edge gain for the peaking overlay.
    public var peakingIntensity: Double = 12
    /// Anamorphic desqueeze factor (1 = spherical).
    public var desqueeze: Double = 1
    /// Punch-in magnification (1 = off).
    public var punchIn: Double = 1
    /// Pan while punched in, in image-fraction units (0 = centered).
    public var panX: Double = 0
    public var panY: Double = 0

    public var anyToolActive: Bool {
        colorTool != .off || zebraOn || peakingOn
    }

    public init() {}
}
