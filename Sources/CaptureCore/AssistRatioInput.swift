import Foundation

/// What an operator TYPES when the presets do not have their show in them.
///
/// The frameline picker offers the six aspects most shows are shot in and the
/// desqueeze picker the five squeeze factors most anamorphics have, and both
/// lists are the common case rather than the whole case: 1.66, 2.76, a 1.25x
/// front element (owner: "desqueze хочу иметь варик писать кастом", "и кастом
/// фреймлайнс тоже"). One parser for both, because an operator typing into
/// either box means the same thing by what they type.
///
/// Deliberately generous about the spelling and strict about the number:
/// a crew says "2.39" and "4:3" for the same kind of thing, a Russian keyboard
/// puts a comma where the decimal point goes, and "1.5x" is how a squeeze
/// factor is written down. What is refused is anything that would leave the
/// operator looking at a picture nothing can be judged from — a zero, a
/// negative, a NaN, or a number outside the range the caller can draw.
public enum AssistRatioInput {
    /// The typed value, or nil — which the field shows by snapping back to
    /// what it had. Refusing visibly beats accepting something unusable:
    /// a frameline at 0 is no frameline, and a desqueeze at 0 is no picture.
    public static func parse(_ text: String,
                             in range: ClosedRange<Double>) -> Double? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
        // "1.5x" — a squeeze factor as it is written on the lens
        if body.hasSuffix("x") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)

        let value: Double?
        if let separator = body.first(where: { $0 == ":" || $0 == "/" }) {
            // "4:3", "16/9" — the same aspect said the other way a crew says it
            let parts = body.split(separator: separator, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  height != 0
            else { return nil }
            value = width / height
        } else {
            value = Double(body)
        }
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// A ratio as the field writes it back: no trailing zeros, and enough
    /// decimals that what comes back out of `parse` is what went in — a field
    /// that rounded 16/9 to 1.78 and then committed that on the next Return
    /// would walk the operator's frameline away from what they asked for.
    public static func text(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Frameline aspects that can actually be drawn inside a frame. 0.2 is
    /// taller than any phone cut and 10 is wider than any screen anybody
    /// frames for; past either the "box" is a line.
    public static let framelineRange: ClosedRange<Double> = 0.2...10
    /// Squeeze factors. 1 is spherical, 2 is the classic anamorphic, and the
    /// range takes in the odd 1.25 front element and the 0.75 an operator
    /// might use to undo a squeeze that is already in the signal.
    public static let desqueezeRange: ClosedRange<Double> = 0.25...4
}
