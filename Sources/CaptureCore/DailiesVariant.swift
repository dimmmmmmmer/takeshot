import Foundation

/// **One more version of the same day** (owner: "и да, очередь из нескольких
/// вариантов дейликов будет супер").
///
/// A unit does not always want one review copy. The edit suite wants ProRes at
/// the full raster, the director wants 720p H.264 on a phone, and the sound
/// department wants something small enough to email — all from the same takes,
/// all in one pass over the footage, because a second pass means somebody has
/// to come back and start it.
///
/// So a run is the sheet's own settings plus a list of these. Each is the
/// three things that make a review copy what it is — how big, in what codec,
/// and what to call it — and nothing else: the burn-ins, the look and the
/// destination stay the run's, because a variant that could change those would
/// not be another version of the same day, it would be a second day's worth of
/// decisions in a row of a list.
///
/// # The suffix is not decoration
///
/// Two variants of one take produce two files in one folder, so their names
/// have to differ or the second lands as `_2` beside the first and nothing in
/// either name says which is which. The suffix is what makes a variant's
/// output identifiable months later, which is why it is a field of the variant
/// and not a setting of the run.
public struct DailiesVariant: Equatable, Sendable, Identifiable {
    /// For SwiftUI's list, and nothing else. Fresh per value on purpose: two
    /// variants that say the same thing are still two rows the operator can
    /// edit apart.
    public let id: UUID
    public var resolution: DailiesResolution
    public var codec: CaptureCodec
    /// What the output is called after the take's own name.
    public var suffix: String

    public init(resolution: DailiesResolution = .hd720,
                codec: CaptureCodec = .h264,
                suffix: String = "_REVIEW", id: UUID = UUID()) {
        self.id = id
        self.resolution = resolution
        self.codec = codec
        self.suffix = suffix
    }

    /// **The persisted form: one string, not an object.**
    ///
    /// `CaptureSettings` is encoded as a FLAT map and the diagnostics bundle's
    /// redaction walks it by key name — nesting is a privacy contract there
    /// rather than a style choice (`SettingsFormatFixture`). A list of objects
    /// would put keys under a key where that filter cannot see them, so a
    /// variant travels as `"<size>|<codec>|<suffix>"` inside a plain array of
    /// strings, exactly as the source and sound folders do.
    ///
    /// `|` because a codec's raw value has spaces in it ("ProRes 422 LT") and
    /// a suffix is an operator's own text; the separator has to be something
    /// neither can contain, and `NameField.prefix` already keeps `|` out of a
    /// file-name field.
    public var stored: String {
        "\(resolution.rawValue)|\(codec.rawValue)|\(suffix)"
    }

    /// One stored variant, or nil when the string says nothing this build can
    /// use. Lenient for the reason every other list in that blob is: one
    /// mangled entry must not cost the others.
    public init?(stored: String) {
        let parts = stored.components(separatedBy: "|")
        guard parts.count == 3,
              let resolution = DailiesResolution(rawValue: parts[0]),
              let codec = CaptureCodec(rawValue: parts[1]),
              CaptureCodec.dailiesChoices.contains(codec)
        else { return nil }
        self.init(resolution: resolution, codec: codec, suffix: parts[2])
    }

    /// How many variants one run may carry.
    ///
    /// Six is already more review copies than any unit ships, and the ceiling
    /// is here because the cost is not the list — it is the PASSES: every
    /// variant is another decode of every take, and a list somebody pastes
    /// into is a night that does not finish.
    public static let limit = 6
}
