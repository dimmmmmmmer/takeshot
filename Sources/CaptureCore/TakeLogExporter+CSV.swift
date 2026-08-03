import Foundation

/// The CSV codec the exporter's three tables share: RFC 4180 escaping on the way
/// out, an RFC 4180 line parser on the way back in, and the newline flattening
/// that makes the round trip possible at all.
///
/// Split out of TakeLogExporter, which wrote three unrelated files (the Resolve
/// metadata CSV, the shift report, the markers sidecar) through this one codec.
/// Nothing here knows what a take is.
extension TakeLogExporter {
    /// The parsers split records on newlines BEFORE unquoting, so multi-line
    /// text must be flattened at the source or the file breaks on restart.
    static func flattened(_ value: String) -> String {
        value.contains(where: \.isNewline)
            ? value.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            : value
    }

    /// RFC 4180 escaping: quote values that contain commas/quotes/newlines.
    /// Values starting with =, +, - or @ are prefixed with an apostrophe —
    /// production opens these CSVs in Excel, where such cells execute as
    /// formulas (a comment like =HYPERLINK(...) is an injection).
    static func escape(_ rawValue: String) -> String {
        var value = rawValue
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        return escapeQuoting(value)
    }

    private static func escapeQuoting(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// RFC 4180 line parser: handles quoted fields with embedded commas/quotes.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"") // escaped quote
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
