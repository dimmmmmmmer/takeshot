import Foundation

/// Экспорт журнала дублей в CSV, совместимый с DaVinci Resolve
/// (Media Pool → Import Metadata: матчинг по File Name, «Good Take» — чекбокс Резолва).
public enum TakeLogExporter {
    public static let fileName = "takeshot-log.csv"

    public static func resolveCSV(takes: [Take]) -> String {
        var lines = ["File Name,Reel Name,Take,Good Take,Comments"]
        for take in takes {
            lines.append([
                escape(take.url.lastPathComponent),
                escape(take.roll.isEmpty ? take.scene : take.roll),
                String(take.takeNumber),
                take.rating == .good ? "true" : "false",
                take.rating == .bad ? "NG" : "",
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

    /// Рейтинги из ранее записанного CSV: имя файла → good/bad.
    /// Используется при восстановлении дублей после перезапуска приложения.
    public static func parseRatings(csv: String) -> [String: TakeRating] {
        var result: [String: TakeRating] = [:]
        for line in csv.split(separator: "\n").dropFirst() {
            // простые строки наш экспорт не квотит; имена с запятыми — редкий случай,
            // такие строки просто пропускаем
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5, !fields[0].hasPrefix("\"") else { continue }
            let name = String(fields[0])
            if fields[3] == "true" {
                result[name] = .good
            } else if fields[4] == "NG" {
                result[name] = .bad
            }
        }
        return result
    }

    /// Экранирование по RFC 4180: кавычки вокруг значений с запятыми/кавычками/переводами строк.
    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
