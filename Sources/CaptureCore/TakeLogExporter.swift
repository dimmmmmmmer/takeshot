import Foundation

/// Экспорт журнала дублей в CSV, совместимый с DaVinci Resolve
/// (Media Pool → Import Metadata: матчинг по File Name, «Good Take» — чекбокс Резолва).
public enum TakeLogExporter {
    public static let fileName = "takeshot-log.csv"

    public static func resolveCSV(takes: [Take]) -> String {
        var lines = ["File Name,Scene,Take,Good Take,Comments"]
        for take in takes {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.scene),
                String(take.takeNumber),
                take.isCircled ? "true" : "false",
                "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Записать журнал в `directory/takeshot-log.csv`. Возвращает URL файла.
    @discardableResult
    public static func write(takes: [Take], toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try resolveCSV(takes: takes).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Экранирование по RFC 4180: кавычки вокруг значений с запятыми/кавычками/переводами строк.
    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
