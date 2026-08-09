import Foundation

/// What the operator dials in on the chroma-key panel: which color is the
/// screen, how much of it counts as screen, how soft the edge is, how hard the
/// spill is pulled out of the subject, and what goes behind the actor.
///
/// A PREVIEW tool. The key is applied in the pipeline's display stage — the
/// same stage the viewing LUT feeds — so it reaches the viewer and the hardware
/// monitor, and it reaches the recorder, the grabs, the scopes and the phone
/// camera grid nowhere at all (see `CapturePipeline+ChromaKey`).
///
/// The math it defines lives in `ChromaKey+Matte`; the CoreImage stage that
/// runs it is `ChromaKeyer`.
public struct ChromaKey: Equatable, Sendable {
    /// A display-RGB triple, 0…1 on gamma-encoded code values (the space every
    /// display buffer in this app is in). A named struct, not a tuple: three
    /// anonymous Doubles in a row is how channels get swapped.
    public struct RGB: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// What shows through where the screen was.
    ///
    /// Persisted by raw value (see `ChromaKeySettings.background`), so
    /// renaming a case silently resets the operator's choice.
    public enum Background: String, CaseIterable, Sendable {
        /// The "is my key clean" view — fringes and holes are unmissable on it.
        case checkerboard
        case color
        /// The intended plate, loaded from a file.
        case image
        /// Black and white alpha, which is how a key is actually judged on set.
        case matte
    }

    /// How the plate is matched to the frame before the manual adjustment.
    ///
    /// Persisted by raw value (`ChromaKeySettings.plateFit`), so renaming
    /// a case silently resets the operator's choice.
    public enum PlateFit: String, CaseIterable, Sendable {
        /// The whole plate inside the frame; the rest is black.
        case fit
        /// The frame covered; whatever hangs over the edge is cropped.
        case fill
        /// The plate distorted to the frame exactly — an aspect the plate was
        /// not made in, which is sometimes the point (a graphic plate authored
        /// for the delivery aspect).
        case stretch
    }

    /// How the plate is laid into the frame, when `background` is `.image`.
    ///
    /// Its own struct because it is the only part of the key that is not about
    /// color at all: the plate arrives at whatever size the art department made
    /// it, and none of the keying math cares where it lands.
    public struct PlateLayout: Equatable, Sendable {
        public var fit: PlateFit = .fit
        /// Magnification ON TOP of the fit (1 = as fitted).
        public var scale: Double = 1
        /// Offset as a fraction of the FRAME, positive x right, positive y up.
        /// In frame units and not plate units so that the slider means the same
        /// thing whatever the plate's own size is.
        public var offsetX: Double = 0
        public var offsetY: Double = 0

        public init() {}

        public static let minScale = 0.25
        public static let maxScale = 4.0
        /// Half a frame either way: past that the plate is off screen and the
        /// operator is dragging a slider with nothing on the other end of it.
        public static let maxOffset = 0.5

        public mutating func clamp() {
            scale = min(Self.maxScale, max(Self.minScale, scale))
            offsetX = min(Self.maxOffset, max(-Self.maxOffset, offsetX))
            offsetY = min(Self.maxOffset, max(-Self.maxOffset, offsetY))
        }

        /// Back to the plain fit, which is what "reset" means here.
        public static let identity = PlateLayout()
    }

    /// OFF by default, and off costs nothing: the display stage checks this one
    /// flag before it touches a pixel.
    public var isOn = false
    /// The screen color. The presets are the digital primaries; a real cyc is
    /// never either of them, which is what the eyedropper is for.
    public var keyColor = RGB(0, 1, 0)
    /// Chroma distance at which a pixel is half keyed — the boundary between
    /// screen and subject, and the only control that decides HOW MUCH of the
    /// screen is keyed at all.
    public var tolerance = 0.20
    /// Width of the feather across that boundary, as a fraction of the
    /// tolerance: 0 is a hard cut exactly at the tolerance, 1 ramps all the way
    /// from the screen color itself to twice the tolerance.
    ///
    /// Relative, and straddling the boundary rather than sitting outside it, so
    /// that it does a job the tolerance does not — see `Kernel.matte`.
    public var softness = 0.5
    /// How much of the screen's hue is pulled out of the subject, 0…1.
    public var spill = 0.5
    public var background: Background = .checkerboard
    /// The solid background, when `background` is `.color`.
    public var backgroundColor = RGB(0, 0, 0)
    /// Where the plate sits, when `background` is `.image`.
    public var plate = PlateLayout()

    public init() {}

    // MARK: - bounds and presets

    /// Slider bounds. Stated here so the panel, the clamps and the tests share
    /// one set of numbers — a slider that can reach a value the setter clamps
    /// away reads as a control that sticks.
    ///
    /// Past ~0.6 of chroma distance a key takes skin with it (measured: skin
    /// sits 0.33 from a lit green cyc, 0.63 from digital green), so that is
    /// where the tolerance stops being a key and starts being a wipe.
    public static let maxTolerance = 0.6
    /// The feather is a FRACTION of the tolerance, so its ceiling is 1: at 1
    /// the ramp runs from the screen color itself out to twice the boundary,
    /// which is as gradual as a key can be and still have a boundary.
    public static let maxSoftness = 1.0

    /// The two screens a unit actually turns up with. Digital primaries rather
    /// than a "typical" cyc color: they are a repeatable starting point, and
    /// the operator lands the real one with the eyedropper in one click.
    public static let greenScreen = RGB(0, 1, 0)
    public static let blueScreen = RGB(0, 0, 1)

    /// Clamp everything the UI can drive to the range the math is defined on.
    /// Called by the setter rather than trusted from the caller: the values also
    /// arrive from a settings blob, which may have been hand-edited.
    public mutating func clamp() {
        keyColor = keyColor.clamped()
        backgroundColor = backgroundColor.clamped()
        tolerance = min(Self.maxTolerance, max(0, tolerance))
        softness = min(Self.maxSoftness, max(0, softness))
        spill = min(1, max(0, spill))
        plate.clamp()
    }
}

extension ChromaKey.RGB {
    /// Into the unit cube. CoreImage clamps anyway; this keeps the pure math
    /// answering the same thing the render does.
    public func clamped() -> Self {
        Self(min(1, max(0, red)), min(1, max(0, green)), min(1, max(0, blue)))
    }

    /// "#RRGGBB" → a triple; an invalid string — nil. The settings blob stores
    /// colors as hex like every other color in this app.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        // `UInt32(_:radix:)` accepts a leading sign, so "+FF000" would parse as
        // 0x0FF000 and a malformed color would silently become a valid one.
        guard value.count == 6, value.allSatisfy(\.isHexDigit),
              let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(Double((rgb >> 16) & 0xFF) / 255,
                  Double((rgb >> 8) & 0xFF) / 255,
                  Double(rgb & 0xFF) / 255)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((min(1, max(0, red)) * 255).rounded()),
               Int((min(1, max(0, green)) * 255).rounded()),
               Int((min(1, max(0, blue)) * 255).rounded()))
    }
}
