import Foundation

/// Values substituted into a filename template.
public struct NamingContext: Sendable {
    public var project: String
    public var date: Date
    public var scene: String
    public var take: Int
    public var reel: String
    public var camera: String
    public var postfix: String
    public var timecode: Timecode?

    public init(project: String = "", date: Date = Date(), scene: String = "",
                take: Int = 0, reel: String = "", camera: String = "",
                postfix: String = "",
                timecode: Timecode? = nil) {
        self.project = project
        self.date = date
        self.scene = scene
        self.take = take
        self.reel = reel
        self.camera = camera
        self.postfix = postfix
        self.timecode = timecode
    }
}

/// Generates filenames from a template with placeholders:
/// {project} {date} {scene} {take} {reel} {cam} {clip} {tc}
/// Unknown placeholders and empty values are dropped; repeated separators collapse.
public struct NamingEngine: Sendable {
    public var template: String
    /// Width of `{clip}`/`{take}`. It says how the template renders a number,
    /// not anything about the take being named, so it belongs with the template.
    public var clipPadding: Int

    public init(template: String, clipPadding: Int = 2) {
        self.template = template
        self.clipPadding = max(1, clipPadding)
    }

    /// Public list — only what's actually set from the UI ({prefix}/{cam}/
    /// {roll}/{clip}/{postfix}) or filled in automatically ({tc}/{date}). The old
    /// names ({project}/{reel}/{take}/{scene}) still work as aliases.
    public static let placeholders = ["{prefix}", "{cam}", "{roll}", "{clip}",
                                      "{postfix}", "{tc}", "{date}", "{yymmdd}",
                                      "{mmdd}", "{hhmm}", "{hhmmss}"]

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Filename without extension, cut to what the file system will accept.
    ///
    /// See `fileNameByteBudget` for the length rule and `shortened` for what a
    /// name over it gives up. Composition is unchanged for every name that
    /// fits, which is all of them until an operator pastes a prefix.
    public func fileName(for context: NamingContext) -> String {
        let composed = compose(context)
        guard Self.exceedsBudget(composed, bytes: Self.fileNameByteBudget,
                                 units: Self.fileNameUnitBudget) else {
            return composed
        }
        return shortened(composed, for: context)
    }

    /// The template filled in — everything except the length budget.
    /// Not private: `shortened` re-composes with a shortened prefix, and it
    /// lives with the length rule in `NamingEngine+Length`.
    func compose(_ context: NamingContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var result = template
        let paddedNumber = context.take >= 0
            ? String(format: "%0\(clipPadding)d", context.take) : ""
        let substitutions: [String: String] = [
            "{project}": context.project,
            "{prefix}": context.project,
            "{date}": dateFormatter.string(from: context.date),
            "{yymmdd}": Self.formatted(context.date, "yyMMdd"),  // ARRI/Sony: 230715
            "{mmdd}": Self.formatted(context.date, "MMdd"),      // RED: 0715
            "{hhmm}": Self.formatted(context.date, "HHmm"),      // BMD: 1234
            "{hhmmss}": Self.formatted(context.date, "HHmmss"),  // ARRI35/Canon: 201535
            // legacy aliases from older templates
            "{date6}": Self.formatted(context.date, "yyMMdd"),
            "{date4}": Self.formatted(context.date, "MMdd"),
            "{time4}": Self.formatted(context.date, "HHmm"),
            "{time6}": Self.formatted(context.date, "HHmmss"),
            "{scene}": context.scene,
            "{take}": paddedNumber,
            "{clip}": paddedNumber,
            "{reel}": context.reel,
            "{roll}": context.reel,
            "{cam}": context.camera,
            "{postfix}": context.postfix,
            "{tc}": context.timecode?.fileNameSafe ?? "",
        ]
        // the project name always prefixes the file, for any vendor preset —
        // unless the template already places {prefix}/{project} itself
        if !context.project.isEmpty,
           !template.contains("{prefix}"), !template.contains("{project}") {
            result = "{prefix}_" + result
        }
        for (key, value) in substitutions {
            result = result.replacingOccurrences(of: key, with: Self.sanitize(value))
        }
        // unknown placeholders {something} — remove
        result = result.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "", options: .regularExpression)
        return Self.collapseSeparators(Self.templateSafe(result))
    }

    // **There is no directory builder here, and that is a decision.** A
    // `relativeDirectory(for:)` used to compose `<project>/<date>/<scene>` and
    // a `pathComponent` hardened each level against a project named `..` — two
    // keystrokes that, before it, wrote the day's takes into the PARENT of the
    // folder the operator chose. Both were dead: the pipeline writes STRAIGHT
    // into the chosen folder (`CapturePipeline+TakeFiles`, "the DIT picks the
    // card/roll folder themselves; app nesting surprises them"), so nothing
    // ever built a path out of them.
    //
    // Kept as a note rather than as code because the hardening only matters
    // for a feature that does not exist: with no nesting there is no level to
    // escape from, and the live path appends a NAME, which `sanitize` and
    // `collapseSeparators` already strip of separators and of leading and
    // trailing dots. Anyone adding subfolders has to bring the dot rule back
    // with them — that is what this paragraph is for.

    /// The forbidden characters of a finished name, applied to the finished
    /// name.
    ///
    /// `fileName(for:)` sanitizes every substituted VALUE, and for years that
    /// looked like enough. It is not: the template itself is free text in
    /// Settings — a plain `TextField`, no input filter — so its literal
    /// characters reach the name untouched. A `/` typed into it is a directory
    /// separator, and a newline or a NUL pasted into it is a name the file
    /// system will refuse outright. Underscore rather than space, because
    /// `collapseSeparators` runs next and folds a run of them into one.
    ///
    /// A no-op for every vendor preset and every hand-written template that
    /// only holds placeholders, separators and letters.
    static func templateSafe(_ value: String) -> String {
        var forbidden = forbiddenFilenameCharacters
        forbidden.formUnion(.controlCharacters)
        forbidden.formUnion(.newlines)
        guard value.unicodeScalars.contains(where: forbidden.contains) else {
            return value
        }
        return String(String.UnicodeScalarView(value.unicodeScalars.map {
            forbidden.contains($0) ? "_" : $0
        }))
    }

    /// What a file name cannot contain. Public because the input filter reads
    /// it too (`NameField`): the field that refuses a keystroke and the pass
    /// that cleans a finished name have to mean the same set, or the operator
    /// gets a character accepted in one place and rewritten in the other.
    public static let forbiddenFilenameCharacters =
        CharacterSet(charactersIn: "/\\:?*<>|\"\0")

    /// Strip characters that are invalid/awkward in filenames.
    public static func sanitize(_ value: String) -> String {
        let forbidden = forbiddenFilenameCharacters
        let cleaned = value.unicodeScalars
            .map { forbidden.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
    }

    /// Collapse repeated separators and trim them at the edges:
    /// "A__T01_" → "A_T01".
    static func collapseSeparators(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"[_\-\. ]{2,}"#, with: "_", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[_\-\. ]+|[_\-\. ]+$"#, with: "", options: .regularExpression)
        return result.isEmpty ? "untitled" : result
    }
}
