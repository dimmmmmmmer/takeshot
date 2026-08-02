import Foundation

/// What the operator dials in on the chroma-key panel: which color is the
/// screen, how much of it counts as screen, how soft the edge is, how hard the
/// spill is pulled out of the subject, and what goes behind the actor.
///
/// A PREVIEW tool. The key is applied in the pipeline's display stage — the
/// same stage the viewing LUT feeds — so it reaches the viewer, the hardware
/// monitor and the phone multiview, and it reaches the recorder, the grabs and
/// the scopes nowhere at all (see `CapturePipeline+ChromaKey`).
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
    /// Persisted by raw value (see `CaptureSettings.chromaKeyBackground`), so
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

    /// OFF by default, and off costs nothing: the display stage checks this one
    /// flag before it touches a pixel.
    public var isOn = false
    /// The screen color. The presets are the digital primaries; a real cyc is
    /// never either of them, which is what the eyedropper is for.
    public var keyColor = RGB(0, 1, 0)
    /// Chroma distance that counts as fully screen (the "similarity" control).
    public var tolerance = 0.20
    /// Chroma distance ABOVE the tolerance over which the matte ramps from
    /// screen to subject — the feather.
    public var softness = 0.10
    /// How much of the screen's hue is pulled out of the subject, 0…1.
    public var spill = 0.5
    public var background: Background = .checkerboard
    /// The solid background, when `background` is `.color`.
    public var backgroundColor = RGB(0, 0, 0)

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
    public static let maxSoftness = 0.4

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
