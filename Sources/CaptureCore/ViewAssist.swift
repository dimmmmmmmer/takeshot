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

    /// A display-RGB tint. A named struct, not a tuple: three anonymous
    /// Doubles in a row is how channels get swapped.
    public struct Tint: Hashable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    /// Peaking overlay tint — the standard monitor palette, not a free color
    /// wheel: the point of each preset is to contrast with a known kind of
    /// subject (red vanishes on skin, white on highlights), and five names the
    /// crew can call out beat an RGB triple nobody can repeat.
    /// Persisted by raw value (see `CaptureSettings.peakingColor`), so renaming
    /// a case silently resets the operator's choice.
    public enum PeakingColor: String, CaseIterable, Sendable {
        case red
        case green
        case blue
        case yellow
        case white

        /// The tint in display RGB, for the renderer and the picker swatch.
        public var components: Tint {
            switch self {
            case .red: return Tint(red: 1, green: 0, blue: 0)
            case .green: return Tint(red: 0, green: 1, blue: 0)
            case .blue: return Tint(red: 0, green: 0, blue: 1)
            case .yellow: return Tint(red: 1, green: 1, blue: 0)
            case .white: return Tint(red: 1, green: 1, blue: 1)
            }
        }
    }

    public var colorTool: ColorTool = .off
    public var zebraOn = false
    /// Zebra trigger level, 0.70…1.0 of full scale.
    public var zebraThreshold: Double = 0.95
    public var peakingOn = false
    /// Edge gain for the peaking overlay.
    public var peakingIntensity: Double = 12
    /// Color of the peaking edges.
    public var peakingColor: PeakingColor = .red
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

    // MARK: - punch-in

    /// Magnification bounds. The pinch gesture and the popover slider share
    /// them, so a trackpad cannot reach a level the panel is unable to show.
    public static let minPunchIn: Double = 1
    public static let maxPunchIn: Double = 8

    /// How far the pan may travel before the punched-in view leaves the
    /// picture: at magnification s only 1/s of the frame is visible, so its
    /// center can move (1 − 1/s)/2 of a frame in each direction. The clamp used
    /// to be a flat ±0.5, which let the operator pan letterbox into the middle
    /// of the image at every magnification.
    public var panLimit: Double {
        punchIn > 1 ? (1 - 1 / punchIn) / 2 : 0
    }

    /// Keep the pan inside `panLimit` (zooming back out has to bring the
    /// picture with it, not leave it parked off-center).
    public mutating func clampPan() {
        let limit = panLimit
        panX = min(limit, max(-limit, panX))
        panY = min(limit, max(-limit, panY))
    }

    /// Set the magnification, clamped, pan kept inside the new frame.
    public mutating func setPunchIn(_ value: Double) {
        punchIn = min(Self.maxPunchIn, max(Self.minPunchIn, value))
        clampPan()
    }

    /// Multiply the magnification (a pinch delta is relative), clamped.
    public mutating func magnify(by factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        setPunchIn(punchIn * factor)
    }

    /// Magnify keeping the image point under `anchor` where it is on screen —
    /// what makes a wheel or pinch zoom land on the thing the pointer is over
    /// instead of the frame center. `anchor` is in viewport coordinates
    /// (y down, the space `ImagePlacement.rect` is stated in).
    ///
    /// The magnification and the pan obey the same clamps as everywhere else,
    /// so near the frame edge the anchor point gives way to the pan limit
    /// rather than pulling letterbox into the picture.
    public mutating func magnify(by factor: Double, at anchor: CGPoint,
                                 sourceSize: CGSize, in viewport: CGSize) {
        guard factor > 0, factor.isFinite else { return }
        guard let before = placement(sourceSize: sourceSize, in: viewport)
        else {
            // nothing on screen to anchor to — a plain clamped magnify
            setPunchIn(punchIn * factor)
            return
        }
        // where the anchor sits on the PICTURE, as a fraction of it
        let u = (anchor.x - before.rect.minX) / before.rect.width
        let v = (anchor.y - before.rect.minY) / before.rect.height
        setPunchIn(punchIn * factor)
        // the centered placement at the new magnification (pan contributes only
        // a shift, so zeroing it reuses the one placement formula instead of
        // growing a second copy of it — see `placement`)
        panX = 0
        panY = 0
        guard punchIn > 1,
              let centered = placement(sourceSize: sourceSize, in: viewport)
        else { return }
        // the pan that puts the same image fraction back under the anchor:
        // anchor.x = centeredMinX − panX·width + u·width, solved for panX
        panX = Double((centered.rect.minX + u * centered.rect.width - anchor.x)
                      / centered.rect.width)
        panY = Double((centered.rect.minY + v * centered.rect.height - anchor.y)
                      / centered.rect.height)
        clampPan()
    }

    /// Pan by a fraction of the whole frame, clamped. Positive `dx` moves the
    /// visible window right, i.e. the picture on screen left.
    public mutating func pan(by delta: CGSize) {
        guard punchIn > 1 else { return }
        panX += Double(delta.width)
        panY += Double(delta.height)
        clampPan()
    }

    // MARK: - where the picture lands

    /// Result of the aspect-fit + punch-in transform.
    public struct ImagePlacement: Equatable, Sendable {
        /// Source pixels → viewport units (fit scale × magnification).
        public var scale: CGFloat
        /// The picture's rect inside the viewport, y growing DOWN (AppKit and
        /// SwiftUI view coordinates). The renderer flips it into CoreImage's
        /// y-up space itself.
        public var rect: CGRect
    }

    /// Where the picture lands inside `viewport`, and at what scale.
    ///
    /// The renderer and the SwiftUI overlays both call this instead of each
    /// keeping a copy of the formula: framelines and safe areas mark the
    /// SIGNAL's geometry, so when the operator punches in they have to ride
    /// exactly the transform the image rides. Two copies of the math is how
    /// they came to disagree — the overlays stayed pinned to the window while
    /// the picture moved under them.
    ///
    /// nil for a degenerate source or viewport (nothing to place).
    public func placement(sourceSize: CGSize,
                          in viewport: CGSize) -> ImagePlacement? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        // at or below 1 punch-in is off; clamping here keeps every caller from
        // having to agree about that separately
        let magnification = CGFloat(max(1, punchIn))
        let fit = min(viewport.width / sourceSize.width,
                      viewport.height / sourceSize.height)
        let scale = fit * magnification
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        // pan is meaningless unmagnified — the picture has nowhere to go
        let shiftX = magnification > 1 ? CGFloat(panX) * width : 0
        let shiftY = magnification > 1 ? CGFloat(panY) * height : 0
        return ImagePlacement(scale: scale, rect: CGRect(
            x: (viewport.width - width) / 2 - shiftX,
            y: (viewport.height - height) / 2 - shiftY,
            width: width, height: height))
    }
}
