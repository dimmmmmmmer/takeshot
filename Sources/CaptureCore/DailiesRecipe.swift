import Foundation

/// **What a run WAS, as one short string** — the thing that decides whether a
/// daily already on disk is the daily this run would make.
///
/// A file with the right name is not the answer: the same take rendered with
/// yesterday's burn-ins, in another codec, or with a look that has since been
/// changed is a different deliverable, and skipping it because the name
/// matches would quietly ship the wrong arrangement to the whole unit. So the
/// journal records the recipe beside each entry and a run compares its own
/// against it.
///
/// Every field that reaches the PICTURE or the FILE is in it and nothing else
/// is: the destination is not (the same daily on another shelf is the same
/// daily), the sound folders are not (a matched file changes the tracks, and
/// the audio verify is what catches a run that should have had sound — this is
/// a decision to revisit if it ever bites), and the run's own order is not.
public enum DailiesRecipe {
    /// The recipe of one run, stable across launches and across machines.
    ///
    /// Built by hand rather than by encoding the structs, and that is the
    /// point of it: a `Codable` fingerprint changes the day somebody adds a
    /// field, which would re-render a whole show's dailies for a property
    /// nothing draws. Adding a line here is a deliberate act, and the test
    /// beside it says which fields are in.
    public static func fingerprint(burnins: DailiesBurnins,
                                   codec: CaptureCodec,
                                   look: DailiesLook? = nil,
                                   desqueeze: Double = 1) -> String {
        var parts: [String] = ["v1", codec.rawValue]
        parts.append("tc:\(flag(burnins.timecode))\(burnins.timecodePosition.rawValue)")
        parts.append("clip:\(flag(burnins.clipName))\(burnins.clipNamePosition.rawValue)")
        parts.append("proj:\(flag(burnins.project))\(burnins.projectPosition.rawValue)")
        parts.append("date:\(flag(burnins.date))\(burnins.datePosition.rawValue)")
        parts.append("custom:\(burnins.customText)@\(burnins.customPosition.rawValue)")
        parts.append("ink:\(number(burnins.ink.plate))/\(number(burnins.ink.text))")
        parts.append("customInk:\(number(burnins.customInk.plate))"
            + "/\(number(burnins.customInk.text))")
        parts.append("look:\(look?.name ?? "-")@\(number(look?.intensity ?? 0))")
        parts.append("desqueeze:\(number(desqueeze))")
        return parts.joined(separator: "|")
    }

    private static func flag(_ on: Bool) -> String { on ? "1" : "0" }

    /// Three decimals, so a slider's own rounding does not re-render a day and
    /// a real change always does. An opacity moves in hundredths on the sheet.
    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
