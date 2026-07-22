import Foundation

/// Values substituted into a filename template.
public struct NamingContext: Sendable {
    public var project: String
    public var date: Date
    public var scene: String
    public var take: Int
    public var reel: String
    public var camera: String
    public var clipName: String
    public var postfix: String
    public var clipPadding: Int
    public var timecode: Timecode?

    public init(project: String = "", date: Date = Date(), scene: String = "",
                take: Int = 0, reel: String = "", camera: String = "",
                clipName: String = "", postfix: String = "", clipPadding: Int = 2,
                timecode: Timecode? = nil) {
        self.project = project
        self.date = date
        self.scene = scene
        self.take = take
        self.reel = reel
        self.camera = camera
        self.clipName = clipName
        self.postfix = postfix
        self.clipPadding = max(1, clipPadding)
        self.timecode = timecode
    }
}

/// Generates filenames from a template with placeholders:
/// {project} {date} {scene} {take} {reel} {cam} {clip} {tc}
/// Unknown placeholders and empty values are dropped; repeated separators collapse.
public struct NamingEngine: Sendable {
    public var template: String

    public init(template: String) {
        self.template = template
    }

    /// Public list — only what's actually set from the UI ({prefix}/{cam}/
    /// {roll}/{clip}/{postfix}) or filled in automatically ({tc}/{date}). The old
    /// names ({project}/{reel}/{take}/{scene}/{clipname}) still work as aliases.
    public static let placeholders = ["{prefix}", "{cam}", "{roll}", "{clip}",
                                      "{postfix}", "{tc}", "{date}", "{date6}",
                                      "{date4}", "{time4}", "{time6}"]

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Filename without extension.
    public func fileName(for context: NamingContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var result = template
        let paddedNumber = context.take >= 0
            ? String(format: "%0\(context.clipPadding)d", context.take) : ""
        let substitutions: [String: String] = [
            "{project}": context.project,
            "{prefix}": context.project,
            "{date}": dateFormatter.string(from: context.date),
            "{date6}": Self.formatted(context.date, "yyMMdd"),   // ARRI/Sony: 230715
            "{date4}": Self.formatted(context.date, "MMdd"),     // RED: 0715
            "{time4}": Self.formatted(context.date, "HHmm"),     // BMD: 1234
            "{time6}": Self.formatted(context.date, "HHmmss"),   // ARRI35/Canon: 201535
            "{scene}": context.scene,
            "{take}": paddedNumber,
            "{clip}": paddedNumber,
            "{reel}": context.reel,
            "{roll}": context.reel,
            "{cam}": context.camera,
            "{clipname}": context.clipName,
            "{postfix}": context.postfix,
            "{tc}": context.timecode?.fileNameSafe ?? "",
        ]
        for (key, value) in substitutions {
            result = result.replacingOccurrences(of: key, with: Self.sanitize(value))
        }
        // unknown placeholders {something} — remove
        result = result.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "", options: .regularExpression)
        return Self.collapseSeparators(result)
    }

    /// Take folder relative to the record root: <project>/<date>/<scene>.
    public func relativeDirectory(for context: NamingContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let components = [context.project, dateFormatter.string(from: context.date), context.scene]
            .map(Self.sanitize)
            .filter { !$0.isEmpty }
        return components.joined(separator: "/")
    }

    /// Strip characters that are invalid/awkward in filenames.
    public static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*<>|\"\0")
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
