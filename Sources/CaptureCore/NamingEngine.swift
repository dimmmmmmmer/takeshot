import Foundation

/// Значения для подстановки в шаблон имени файла.
public struct NamingContext: Sendable {
    public var project: String
    public var date: Date
    public var scene: String
    public var take: Int
    public var reel: String
    public var camera: String
    public var clipName: String
    public var postfix: String
    public var timecode: Timecode?

    public init(project: String = "", date: Date = Date(), scene: String = "",
                take: Int = 0, reel: String = "", camera: String = "",
                clipName: String = "", postfix: String = "", timecode: Timecode? = nil) {
        self.project = project
        self.date = date
        self.scene = scene
        self.take = take
        self.reel = reel
        self.camera = camera
        self.clipName = clipName
        self.postfix = postfix
        self.timecode = timecode
    }
}

/// Генерация имён файлов по шаблону с плейсхолдерами:
/// {project} {date} {scene} {take} {reel} {cam} {clip} {tc}
/// Неизвестные плейсхолдеры и пустые значения выпадают, повторные разделители схлопываются.
public struct NamingEngine: Sendable {
    public var template: String

    public init(template: String) {
        self.template = template
    }

    /// Публичный список — только то, что реально задаётся из UI ({prefix}/{cam}/
    /// {roll}/{clip}/{postfix}) или подставляется само ({tc}/{date}). Старые имена
    /// ({project}/{reel}/{take}/{scene}/{clipname}) продолжают работать как алиасы.
    public static let placeholders = ["{prefix}", "{cam}", "{roll}", "{clip}",
                                      "{postfix}", "{tc}", "{date}"]

    /// Имя файла без расширения.
    public func fileName(for context: NamingContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var result = template
        let paddedNumber = context.take >= 0 ? String(format: "%02d", context.take) : ""
        let substitutions: [String: String] = [
            "{project}": context.project,
            "{prefix}": context.project,
            "{date}": dateFormatter.string(from: context.date),
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
        // неизвестные плейсхолдеры {что-то} — убрать
        result = result.replacingOccurrences(of: #"\{[^{}]*\}"#, with: "", options: .regularExpression)
        return Self.collapseSeparators(result)
    }

    /// Папка дубля относительно корня записи: <проект>/<дата>/<сцена>.
    public func relativeDirectory(for context: NamingContext) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let components = [context.project, dateFormatter.string(from: context.date), context.scene]
            .map(Self.sanitize)
            .filter { !$0.isEmpty }
        return components.joined(separator: "/")
    }

    /// Убрать из значения символы, недопустимые/неудобные в именах файлов.
    static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*<>|\"\0")
        let cleaned = value.unicodeScalars
            .map { forbidden.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
    }

    /// Схлопнуть повторные разделители и обрезать их по краям:
    /// "A__T01_" → "A_T01".
    static func collapseSeparators(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"[_\-\. ]{2,}"#, with: "_", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[_\-\. ]+|[_\-\. ]+$"#, with: "", options: .regularExpression)
        return result.isEmpty ? "untitled" : result
    }
}
