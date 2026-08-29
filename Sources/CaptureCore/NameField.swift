import Foundation

/// What each field that feeds a filename will accept — checked per keystroke,
/// not after the fact (owner item 28).
///
/// The fields used to let an invalid character be typed and then erase it a
/// moment later. That is worse than either alternative: the operator sees their
/// input accepted and then silently altered, which on a naming field reads as
/// the app losing what they typed. The rule lives here, in one value per field,
/// so that the thing that REJECTS a keystroke and the thing that sanitizes a
/// finished name cannot disagree — `normalized` is the input filter and
/// `NamingEngine.sanitize` is the last line, and everything the first one lets
/// through the second one leaves alone.
public enum NameField: String, CaseIterable, Sendable {
    /// The project name — `{prefix}` in the template.
    case prefix
    case camera
    case roll
    case clip
    case postfix
    case scene
    case shot
    /// The take number inside the scene.
    case take

    /// Longest value the field takes; nil — no limit.
    ///
    /// Only the counters are capped, and at the width the controller clamps
    /// them to anyway (`min(9999, …)`): a fifth digit is not a value the app
    /// can hold, so refusing the keystroke is more honest than accepting it and
    /// rounding it down.
    public var maxLength: Int? {
        switch self {
        case .clip, .take: return 4
        default: return nil
        }
    }

    /// The text as the field will hold it: refused characters removed, and the
    /// one case fold the fields apply (camera labels are upper case).
    ///
    /// The result is what actually appears — a formatter installs it in place
    /// of the proposed edit, so a refused character never reaches the screen.
    public func normalized(_ text: String) -> String {
        let cased = self == .camera ? text.uppercased() : text
        var out = String(String.UnicodeScalarView(
            cased.unicodeScalars.filter(accepts)))
        if let maxLength, out.count > maxLength {
            out = String(out.prefix(maxLength))
        }
        return out
    }

    /// Whether the field would have let the operator type this — the question a
    /// test asks, and the guard a paste has to pass.
    public func accepts(_ text: String) -> Bool { normalized(text) == text }

    private func accepts(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .camera:
            // plain uppercase latin: a camera label lands in file names on
            // other people's systems, and "Б" is not a camera anybody can call
            return ("A"..."Z").contains(scalar)
        case .clip, .take, .shot:
            // Shot joined these when it stopped being a setup LETTER and became
            // a shot number — "сцена 1 кадр 1 дубль 1". A field that still
            // accepted "A" would let an operator type a value the model has
            // nowhere to put.
            return ("0"..."9").contains(scalar)
        case .roll:
            // a reel name goes into the CSV's Reel Name column and into every
            // NLE that reads it: alphanumerics and the two separators nobody
            // has ever had trouble with
            return ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        case .prefix, .postfix, .scene:
            // free text, minus what a file system cannot hold. Spaces stay —
            // "12 A" is a scene, and `NamingEngine.sanitize` turns the space
            // into an underscore when it builds the name.
            return !NamingEngine.forbiddenFilenameCharacters.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
