import Foundation

/// Operator display aids, applied identically on every surface: the viewer,
/// the fullscreen windows, the director's monitor, the hardware playout and
/// the phone multiview.
///
/// The value is one bundle because it travels as one: the whole set is dialled
/// in the same popover and has to ride the same draft/debounce path a slider
/// needs. Where each member is APPLIED differs, and each says so at its own
/// declaration — the colour tools and the guides in the shared display stage
/// (`AssistStage`), the chroma key one stage before it, the desqueeze and the
/// punch-in in the per-surface render, because those are geometry and a
/// surface is the only thing that knows its own viewport.
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
    /// Persisted by raw value (see `AssistSettings.peakingColor`), so renaming
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
    /// Edge gain for the peaking overlay — the renderer's unit, which is the
    /// `CIEdges` intensity. The panel shows it as a percentage instead (see
    /// `peakingPercent`): 2…30 is a number out of the filter's documentation
    /// and means nothing to an operator.
    public var peakingIntensity: Double = 12
    /// Color of the peaking edges.
    public var peakingColor: PeakingColor = .red
    /// Framelines and safe areas. Drawn in the display stage beside the colour
    /// tools, at the signal's own resolution (see `AssistGuides`).
    public var guides = AssistGuides()
    /// Size and edge of the exposure legend — the key to what `colorTool` is
    /// painting. Drawn in the display stage on top of everything else, so it
    /// reaches the hardware monitor with the aid it explains (see
    /// `AssistLegend`); with no colour tool on there is no legend to draw.
    public var legend = AssistLegend()
    /// Anamorphic desqueeze factor (1 = spherical).
    public var desqueeze: Double = 1
    /// Punch-in magnification (1 = off).
    public var punchIn: Double = 1
    /// Pan while punched in, in image-fraction units (0 = centered).
    public var panX: Double = 0
    public var panY: Double = 0
    /// **The five sizing controls this app had no way to set** — the rest of
    /// `PictureSizing`'s nine, which the renderer has understood since the
    /// sizing type existed and nothing could reach.
    ///
    /// Neutral by default and therefore free: a `PictureSizing` with these at
    /// their defaults is the transform the app has always applied, and the
    /// renderer's own fast paths key off `isIdentity` and `isAffine` rather
    /// than off which fields exist.
    ///
    /// `height` is `width`'s twin — `width` is the anamorphic desqueeze under
    /// its Resolve name — and the two are independent on purpose: a squeezed
    /// source is corrected on one axis, and a deliverable that has to fill a
    /// different aspect is corrected on the other.
    public var height: Double = 1
    /// Degrees, positive clockwise as the operator sees it.
    public var rotation: Double = 0
    /// The two non-affine terms. A pick from the picture is refused while
    /// either is set — see `PictureSizing.isAffine`.
    public var pitch: Double = 0
    public var yaw: Double = 0
    public var flipH = false
    public var flipV = false
    /// **The playback surfaces' own geometry**, or nil while they share the
    /// live one (owner: the nine controls wanted separately for playback and
    /// for record viewing).
    ///
    /// Carried HERE rather than on the controller so that one value, one
    /// draft and one debounce hold both sets — a second copy of that
    /// machinery is how two surfaces come to disagree about where a gesture
    /// got to. The risk that buys is the one this type's own note warns
    /// about, a value carrying a transform for somebody else, and it is
    /// closed by construction: no surface is ever handed this value. They are
    /// handed `forLive` or `forPlayback`, and each of those has the nine of
    /// exactly one surface and no second set at all.
    ///
    /// Session state, deliberately. The live set persists because it is about
    /// the RIG — a camera mounted upside down is flipped once — and a
    /// playback geometry is about the clip somebody is looking at right now.
    /// It starts as a copy of the live set, so a unit that never touches it
    /// sees exactly what this app has always shown.
    public var playbackSizing: PictureSizing?
    /// The chroma-key preview. Carried here, applied elsewhere: the pipeline
    /// splits it out in `setViewAssist` and runs it one stage BEFORE the aids,
    /// so that a false colour meters the picture the key produced rather than
    /// the green screen behind it. Deliberately absent from `anyToolActive`
    /// below — that flag asks whether the assist stage has a filter pass to
    /// run, and for the key it never does.
    public var chroma = ChromaKey()

    /// Whether the assist stage has a FILTER pass to run. The guides are asked
    /// for separately (`guides.isEmpty`): they are drawn, not computed, and a
    /// frameline with no exposure tool must still cost a pass.
    public var anyToolActive: Bool {
        colorTool != .off || zebraOn || peakingOn
    }

    /// Whether anything the operator switched on is on the picture — what the
    /// assist badge lights up for.
    ///
    /// Not `self != ViewAssist()`, which is what the badge used to ask: the
    /// chroma key's dial-in is persisted while the key itself stays off, so a
    /// remembered tolerance would leave the badge lit for the rest of the
    /// project. Each aid is named here instead, and a stored value that nothing
    /// is showing counts for nothing.
    public var isShowingAid: Bool {
        anyToolActive || !guides.isEmpty || desqueeze != 1 || punchIn > 1
            || chroma.isOn
    }

    public init() {}

    /// **The same set-up with nothing DRAWN on the picture** — what the
    /// bypass key shows (owner: "нам нужен хоткей типа … включить/отключить её
    /// видимость").
    ///
    /// The tools and the guides go; the GEOMETRY stays. A desqueeze and a
    /// punch-in are how the operator is framing the shot, not marks over it,
    /// and a key that unzoomed the picture on its way to hiding a zebra would
    /// be the opposite of a bypass. The chroma key goes with the drawing half:
    /// it replaces the background, which is the most drawn-on a picture gets,
    /// and its dial-in is kept because this value is a COPY — nothing is
    /// forgotten, and pressing the key again brings all of it back.
    public var withoutAids: ViewAssist {
        var bare = self
        bare.colorTool = .off
        bare.zebraOn = false
        bare.peakingOn = false
        bare.guides = AssistGuides()
        bare.chroma.isOn = false
        return bare
    }

    /// **Everything the assist popover holds, back to how it ships** — what
    /// the reset key does (owner: "сбросить все по опер помощи").
    ///
    /// The chroma key's dial-in survives: a colour picked off the green screen
    /// and a tolerance dialled in over ten minutes is set-up, and the switch
    /// beside it is what "reset" is about. Everything else — the exposure
    /// tools, the guides, the legend, the desqueeze and the punch-in — is the
    /// value this type ships with.
    public var reset: ViewAssist {
        var fresh = ViewAssist()
        fresh.chroma = chroma
        fresh.chroma.isOn = false
        return fresh
    }

    // MARK: - focus peaking

    /// Edge gain at 100 %. The old slider's ceiling, kept: 30 is where every
    /// grain of noise on an underexposed frame is already an "edge", so past it
    /// the tool stops answering the question it is for.
    public static let maxPeakingIntensity: Double = 30

    /// The renderer's edge gain for a 0…100 % sensitivity.
    ///
    /// Straight proportion, and the floor is a real zero rather than the 2 the
    /// slider used to stop at: `CIEdges` at 0 finds no edges, so 0 % means what
    /// it says instead of "the faintest peaking there is".
    public static func peakingIntensity(forPercent percent: Double) -> Double {
        maxPeakingIntensity * min(100, max(0, percent)) / 100
    }

    /// The percentage a stored edge gain shows as — the inverse of the above,
    /// which is what makes a value written by an older build (2…30) come back
    /// as a sensible position on the new slider instead of being reset.
    public static func peakingPercent(forIntensity intensity: Double) -> Double {
        min(100, max(0, intensity)) / maxPeakingIntensity * 100
    }

    /// Focus-peaking sensitivity as the panel states it, 0…100 %.
    public var peakingPercent: Double {
        get { Self.peakingPercent(forIntensity: peakingIntensity) }
        set { peakingIntensity = Self.peakingIntensity(forPercent: newValue) }
    }

    // MARK: - punch-in

    /// Magnification bounds. The pinch gesture and the popover slider share
    /// them, so a trackpad cannot reach a level the panel is unable to show.
    ///
    /// 10 and not the 8 it shipped with: on a 4K signal in a windowed player a
    /// focus check on an eyelash is still short of pixel-for-pixel at 8×.
    public static let minPunchIn: Double = 1
    public static let maxPunchIn: Double = 10

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
        // **Which pixel of the SOURCE is under the pointer**, asked through
        // the matrix rather than by interpolating across the picture's
        // bounding box: under a rotation or a flip those are different points,
        // and the whole promise of this function is that one of them stays put.
        guard let fraction = imageFraction(of: anchor, sourceSize: sourceSize,
                                           in: viewport) else {
            // nothing on screen to anchor to — a plain clamped magnify
            setPunchIn(punchIn * factor)
            return
        }
        setPunchIn(punchIn * factor)
        // The centred geometry at the new magnification: the pan contributes
        // only a shift, so zeroing it reuses the one formula instead of
        // growing a second copy of it — see `surfaceTransform`.
        panX = 0
        panY = 0
        guard punchIn > 1,
              let centred = surfaceTransform(sourceSize: sourceSize,
                                             in: viewport),
              let picture = placement(sourceSize: sourceSize, in: viewport)
        else { return }
        let landed = CGPoint(x: fraction.x * sourceSize.width,
                             y: fraction.y * sourceSize.height)
            .applying(centred)
        // …and the pan that puts it back under the anchor. A pan moves the
        // picture by a fraction of its own size on screen, and a POSITIVE one
        // moves it left and up (`PictureSizing.transform`, step 5), which is
        // why the difference is taken this way round.
        panX = Double((landed.x - anchor.x) / picture.rect.width)
        panY = Double((landed.y - anchor.y) / picture.rect.height)
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

    /// **The geometry, as the one value that knows how to place a picture.**
    ///
    /// The numbers above are this app's own spelling of `PictureSizing`'s
    /// nine, and the renderer goes through the new type: two transforms doing
    /// the same arithmetic is exactly how the overlays and the picture came
    /// apart the first time. Until the three independent sets exist (live,
    /// playback, record), this is where a surface gets its sizing from.
    ///
    /// Public because the sizing POPOVER reads it — to tint its badge and to
    /// say when the transform has stopped being affine — and asking the nine
    /// fields one at a time at a call site is how a tenth gets forgotten.
    public var sizing: PictureSizing {
        var value = PictureSizing()
        value.width = desqueeze
        value.height = height
        value.zoom = punchIn
        value.panX = panX
        value.panY = panY
        value.rotation = rotation
        value.pitch = pitch
        value.yaw = yaw
        value.flipH = flipH
        value.flipV = flipV
        return value
    }

    /// What the LIVE surfaces get: this value with no second set on it.
    public var forLive: ViewAssist { with(sizing: sizing) }

    /// What the PLAYBACK surfaces get: the same aids over their own geometry,
    /// or over the live one while they share it.
    public var forPlayback: ViewAssist { with(sizing: playbackSizing ?? sizing) }

    /// A copy whose nine controls are `sizing` — and which carries no second
    /// set, so what comes out of here can only ever describe one surface.
    public func with(sizing: PictureSizing) -> ViewAssist {
        var copy = self
        copy.playbackSizing = nil
        copy.desqueeze = sizing.width
        copy.height = sizing.height
        copy.punchIn = sizing.zoom
        copy.panX = sizing.panX
        copy.panY = sizing.panY
        copy.rotation = sizing.rotation
        copy.pitch = sizing.pitch
        copy.yaw = sizing.yaw
        copy.flipH = sizing.flipH
        copy.flipV = sizing.flipV
        return copy
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

    /// **Source pixels to points on a surface**, y DOWN — the one matrix the
    /// overlays and the mouse ride.
    ///
    /// Two transforms in a row, because that is what actually happens to the
    /// picture now:
    ///
    /// 1. the nine controls, INTO THE SIGNAL'S OWN RASTER — where the display
    ///    stage applies them, so that the hardware playout, the multiview and
    ///    the phone grid carry the operator's reframe and not just this
    ///    window (`AssistStage.rendered`);
    /// 2. that raster aspect-fitted into the surface, which is the only part
    ///    a window still decides for itself (`MetalPreviewLayer`).
    ///
    /// `sourceSize` is the SIGNAL's raster and not the desqueezed picture: the
    /// desqueeze is one of the nine and is applied in step 1, inside the
    /// raster, which is why an anamorphic feed now goes out letterboxed in
    /// 16:9 instead of only looking right in this app.
    ///
    /// nil under a pitch or a yaw — there is no affine inverse then and a pick
    /// must be refused rather than land on the wrong pixel — and nil for a
    /// degenerate source or viewport.
    public func surfaceTransform(sourceSize: CGSize,
                                 in viewport: CGSize) -> CGAffineTransform? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              viewport.width > 0, viewport.height > 0,
              let sized = sizing.transform(sourceSize: sourceSize,
                                           in: sourceSize) else { return nil }
        let fit = min(viewport.width / sourceSize.width,
                      viewport.height / sourceSize.height)
        return sized
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(
                translationX: (viewport.width - sourceSize.width * fit) / 2,
                y: (viewport.height - sourceSize.height * fit) / 2))
    }

    /// Where the picture lands inside `viewport`, and at what scale.
    ///
    /// The SwiftUI overlays and the two gestures call this instead of each
    /// keeping a copy of the formula: framelines and safe areas mark the
    /// SIGNAL's geometry, so when the operator reframes they have to ride
    /// exactly the transform the image rides. Two copies of the math is how
    /// they came to disagree — the overlays stayed pinned to the window while
    /// the picture moved under them.
    ///
    /// The rect is the picture's BOUNDING BOX, which is the whole of it for
    /// the eight controls that keep it square to the frame and its extent
    /// under a rotation. `scale` is that box against the source.
    ///
    /// nil for a degenerate source or viewport, and under a pitch or a yaw —
    /// see `surfaceTransform`.
    public func placement(sourceSize: CGSize,
                          in viewport: CGSize) -> ImagePlacement? {
        guard let matrix = surfaceTransform(sourceSize: sourceSize,
                                            in: viewport) else { return nil }
        let rect = CGRect(origin: .zero, size: sourceSize).applying(matrix)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return ImagePlacement(scale: rect.width / sourceSize.width, rect: rect)
    }

    /// Where a point on the SURFACE lands on the picture, as fractions of the
    /// frame (0,0 top-left, y down like the placement it inverts). nil when the
    /// point is off the picture — on the letterbox, or outside a punched-in
    /// crop — because there is no pixel there to answer for.
    ///
    /// The inverse of `placement`, and it lives beside it for the reason the
    /// overlays read `placement` instead of keeping their own copy: the
    /// eyedropper has to hit the pixel the operator is pointing at through the
    /// desqueeze, the punch-in and the pan, and a second copy of that transform
    /// is how the two come to disagree.
    public func imageFraction(of point: CGPoint, sourceSize: CGSize,
                              in viewport: CGSize) -> CGPoint? {
        guard let matrix = surfaceTransform(sourceSize: sourceSize,
                                            in: viewport),
              matrix.a * matrix.d - matrix.b * matrix.c != 0 else { return nil }
        // Through the matrix and not across the placement rect: a rotated or
        // flipped picture's bounding box says nothing about which pixel is
        // under the pointer, and the eyedropper has to hit the one the
        // operator is pointing at.
        let source = point.applying(matrix.inverted())
        let u = source.x / sourceSize.width
        let v = source.y / sourceSize.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}
