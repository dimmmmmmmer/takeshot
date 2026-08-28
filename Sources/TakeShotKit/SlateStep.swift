import Foundation

/// One press of the ‹ › arrows beside a slate field.
///
/// Scene, shot and take are TEXT — a scene is "12", "12A" or "112A pickup", a
/// shot is a letter — so "step the value" has to be defined before an arrow can
/// do it. One rule covers all three, and it is the numbering convention a slate
/// already uses: **page the trailing token.**
///
/// - Ends in digits → step that number, keeping any zero padding. "12" → "13",
///   "007" → "008".
/// - Ends in a single letter with a digit or nothing before it → step the
///   letter, A…Z, case kept. "12A" → "12B", "B" → "C".
/// - Anything else is free text and the arrows leave it alone (and go grey —
///   see `canStep`). "112A pickup" is a scene an operator typed a note into;
///   turning it into "112A pickuq" is not paging, it is corruption.
///
/// **Empty is a value, at the bottom of the ladder.** Stepping down off the
/// first one empties the field rather than clamping at it — an empty slate
/// field means "not logged", and for the take number specifically it means
/// "follow the clip counter" (`slate_take_help`), so it has to be reachable with
/// the arrows and not only by selecting the text and deleting it. Stepping up
/// from empty gives the field's first value, which is why `seed` is a parameter:
/// scenes and takes start at 1, shots at A.
enum SlateStep {
    /// Nothing pages past this, and nothing TYPED past it either:
    /// `SlateTakeField.maximum` is defined as this number rather than as a
    /// second `9999`, which is what makes the arrows and the keyboard one
    /// control. The field itself takes four digits at most.
    static let maxNumber = 9999

    /// The value after one press, or `value` unchanged when there is nothing to
    /// page (see `canStep`, which is what greys the arrow out first).
    static func stepped(_ value: String, by delta: Int, seed: String) -> String {
        guard delta != 0 else { return value }
        if value.isEmpty { return delta > 0 ? seed : "" }
        if let start: String.Index = digitRunStart(of: value) {
            return steppingDigits(in: value, from: start, by: delta)
        }
        if let letter: Character = pageableLetter(of: value) {
            return steppingLetter(letter, in: value, by: delta)
        }
        return value
    }

    /// Whether the arrow in that direction can do anything — an arrow that
    /// would be a no-op is disabled rather than dead under the pointer.
    static func canStep(_ value: String, by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        if value.isEmpty { return delta > 0 }
        return digitRunStart(of: value) != nil || pageableLetter(of: value) != nil
    }

    // MARK: - the two tokens

    /// Where the trailing run of ASCII digits begins, or nil if the value does
    /// not end in one.
    private static func digitRunStart(of value: String) -> String.Index? {
        guard let last: Character = value.last, isDigit(last) else { return nil }
        var start: String.Index = value.endIndex
        while start > value.startIndex {
            let previous: String.Index = value.index(before: start)
            guard isDigit(value[previous]) else { break }
            start = previous
        }
        return start
    }

    /// The trailing letter, if it is one the arrows may page: a single ASCII
    /// letter with a digit or nothing in front of it. That is what tells "12A"
    /// and "B" from the last letter of a word.
    private static func pageableLetter(of value: String) -> Character? {
        guard let last: Character = value.last, isLetter(last) else { return nil }
        let lastIndex: String.Index = value.index(before: value.endIndex)
        guard lastIndex > value.startIndex else { return last }
        let before: Character = value[value.index(before: lastIndex)]
        return isDigit(before) ? last : nil
    }

    // MARK: - stepping them

    private static func steppingDigits(in value: String, from start: String.Index,
                                       by delta: Int) -> String {
        let head: String = String(value[value.startIndex..<start])
        let digits: String = String(value[start..<value.endIndex])
        let next: Int = (Int(digits) ?? 0) + delta
        // off the bottom: the run goes, which empties a field that was only the
        // number — the "not logged" state, reached with the arrow
        guard next >= 1 else { return head }
        let capped: Int = min(maxNumber, next)
        let plain: String = String(capped)
        // "007" → "008", not "8": the padding is the operator's, not ours
        guard digits.count > plain.count, digits.hasPrefix("0") else {
            return head + plain
        }
        let zeros: String = String(repeating: "0", count: digits.count - plain.count)
        return head + zeros + plain
    }

    private static func steppingLetter(_ letter: Character, in value: String,
                                       by delta: Int) -> String {
        let head: String = String(value[value.startIndex..<value.index(
            before: value.endIndex)])
        guard let scalar: Unicode.Scalar = letter.unicodeScalars.first else {
            return value
        }
        let base: UInt32 = letter.isUppercase ? 65 : 97 // "A" / "a"
        let offset: Int = Int(scalar.value) - Int(base) + delta
        // below A the letter goes — "12A" → "12", "B" alone → empty
        guard offset >= 0 else { return head }
        guard let next: Unicode.Scalar = Unicode.Scalar(base + UInt32(min(25, offset)))
        else { return value }
        return head + String(Character(next))
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }
}
