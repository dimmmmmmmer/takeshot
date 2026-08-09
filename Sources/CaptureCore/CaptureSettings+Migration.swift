import Foundation

/// What happens to a settings blob written by an older build.
///
/// Most changes need nothing here: an added field is Optional so it decodes as
/// nil, and a removed one is dropped by the synthesized decoder. This is for
/// the changes that cannot be expressed that way — a value that still decodes
/// and now MEANS something else, or a feature retired into another one.
extension CaptureSettings {
    /// Schema version of what this build writes. Bump it when a change cannot be
    /// expressed by "add an Optional field", and add the step to `migrate`.
    ///
    /// 1 — everything up to and including the naming-template migrations below,
    ///     which used to run unconditionally on every load.
    /// 2 — the two input-levels modes collapsed into one, and the retired
    ///     verified-backup folder handed to the offload destinations.
    /// 3 — the exposure legend moved from four corners to four edges, and the
    ///     chroma key's softness from an absolute feather to a relative one.
    ///     Both are re-readings of a value that is still in range, which is
    ///     exactly the change an Optional field cannot express.
    ///
    /// Grouping the fields was NOT such a change and did not bump this: the
    /// encoded shape is identical either side of it, which is what
    /// `ModelSettingsFormatTests` exists to prove.
    public static var currentSchemaVersion: Int { 3 }

    /// Explicit, ordered migration chain. Previously every rule below ran on
    /// every load forever, which quietly forbids ever reusing an old template
    /// string and gives no place to put a change that is not a new Optional.
    ///
    /// `retired` carries the fields that are no longer on this type at all: the
    /// synthesized decoder drops unknown keys, so a migration that has to READ
    /// a removed field needs it decoded separately.
    static func migrate(_ input: CaptureSettings,
                        retired: RetiredSettings = RetiredSettings()) -> CaptureSettings {
        var settings = input
        if (settings.schemaVersion ?? 0) < 1 {
            settings = migrateToVersion1(settings)
        }
        if (settings.schemaVersion ?? 0) < 2 {
            settings = migrateToVersion2(settings, retired: retired)
        }
        if (settings.schemaVersion ?? 0) < 3 {
            settings = migrateToVersion3(settings, retired: retired)
        }
        return settings
    }

    /// The legend's corner became an edge, and the key's softness became a
    /// fraction of its tolerance.
    ///
    /// Both values would still decode as they stand and both would mean
    /// something else, which is the case a version number exists for.
    static func migrateToVersion3(
        _ input: CaptureSettings, retired: RetiredSettings) -> CaptureSettings {
        var settings = input
        // Four corners → four edges. The side the corner was on says nothing
        // about a strip that now spans the whole edge, so only top vs bottom
        // carries over — and bottom is the new default, i.e. nil.
        if settings.assist.legendPlacement == nil,
           let corner = retired.legendCorner, corner.hasPrefix("top") {
            settings.assist.legendPlacement = "top"
        }
        // The feather used to be an absolute chroma width hung outside the
        // tolerance (tolerance … tolerance + softness) and is now a fraction of
        // the tolerance straddling it (t·(1−s) … t·(1+s)). Converting on the
        // WIDTH keeps the edge exactly as gradual as the operator left it:
        // 2·t·new = old.
        if let stored = settings.chromaKey.softness {
            let tolerance = settings.chromaKey.tolerance ?? ChromaKey().tolerance
            settings.chromaKey.softness = tolerance > 0.01
                ? min(1, stored / (2 * tolerance)) : 0
        }
        return settings
    }

    /// Input levels lost their second studio-swing mode, and the app lost the
    /// verified-backup folder to the DIT offload.
    private static func migrateToVersion2(
        _ input: CaptureSettings, retired: RetiredSettings) -> CaptureSettings {
        var settings = input
        // There is one Limited now, and it is the excursion-preserving reading
        // — so the operator who had asked for that keeps exactly what they had,
        // and the one who had the clamping reading is moved off it deliberately.
        if settings.capture.videoLevels == "limited_excursions" {
            settings.capture.videoLevels = InputLevels.limited.rawValue
        }
        // The offload supersedes the verified backup, and its destination list
        // is where that folder belongs. Adopted only when the operator has not
        // already set one up: their own list is never second-guessed.
        if settings.offload.destinationPaths == nil, let backup = retired.backupPath {
            settings.offload.destinationPaths = [backup]
        }
        return settings
    }

    private static func migrateToVersion1(_ input: CaptureSettings) -> CaptureSettings {
        var settings = input
        // migrate default templates from earlier versions
        if ["{scene}_T{take}_{cam}_{tc}",
            "{prefix}_{cam}_{roll}_C{clip}",
            "{prefix}_{cam}_{roll}_C{clip}_{postfix}"].contains(settings.naming.namingTemplate) {
            settings.naming.namingTemplate = CaptureSettings().naming.namingTemplate
        }
        // presets from before the vendor date formats ({date6}/{date4}/{time4})
        let presetMigrations = [
            "{cam}{roll}C{clip}_{date}_{postfix}": "{cam}{roll}C{clip}_{date6}_{postfix}",
            "{cam}{roll}_C{clip}_{date}_{postfix}": "{cam}{roll}_C{clip}_{date4}{postfix}",
            "{cam}{roll}C{clip}_{date}{postfix}": "{cam}{roll}C{clip}_{date6}{postfix}",
            "{cam}{roll}_{date}_C{clip}": "{cam}{roll}_{date4}{time4}_C{clip}",
        ]
        for (old, new) in [("{date6}", "{yymmdd}"), ("{date4}", "{mmdd}"),
                           ("{time4}", "{hhmm}"), ("{time6}", "{hhmmss}")] {
            settings.naming.namingTemplate =
                settings.naming.namingTemplate.replacingOccurrences(of: old, with: new)
        }
        if let migrated = presetMigrations[settings.naming.namingTemplate] {
            settings.naming.namingTemplate = migrated
        }
        return settings
    }
}
