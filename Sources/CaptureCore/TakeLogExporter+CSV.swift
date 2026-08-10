import Foundation

/// The CSV codec the exporter's four tables share: RFC 4180 escaping on the way
/// out, an RFC 4180 parser on the way back in, and the newline flattening that
/// keeps a free-text value on one row.
///
/// Split out of TakeLogExporter, which wrote three unrelated files (the Resolve
/// metadata CSV, the shift report, the markers sidecar) through this one codec.
/// Nothing here knows what a take is.
extension TakeLogExporter {
    /// Free text on one line.
    ///
    /// The set is `CharacterSet.newlines`, which is the same set
    /// `Character.isNewline` answers for and therefore the same set the record
    /// parser below breaks on — that agreement is the whole point. It used to
    /// be the three ASCII endings only, so a comment pasted out of Word or a
    /// browser (U+2028 LINE SEPARATOR is what those produce) went into the file
    /// with a break the writer had not seen and the reader had: one take's row
    /// became two, and in `takeshot-slate.csv` the short first half no longer
    /// had five columns and the whole row was dropped on the next scan. The
    /// operator's scene, shot and description disappeared silently.
    ///
    /// CRLF is collapsed first so that the commonest of them still costs one
    /// space rather than two.
    static func flattened(_ value: String) -> String {
        guard value.contains(where: \.isNewline) else { return value }
        return value.replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
    }

    /// RFC 4180 escaping: quote values that contain commas, quotes or a line
    /// break. Values starting with =, +, - or @ are prefixed with an apostrophe
    /// — production opens these CSVs in Excel, where such cells execute as
    /// formulas (a comment like =HYPERLINK(...) is an injection).
    static func escape(_ rawValue: String) -> String {
        var value = rawValue
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        return escapeQuoting(value)
    }

    /// The inverse of the formula guard, applied to every value read back.
    ///
    /// Without it the apostrophe is not an escape but an edit: a comment typed
    /// as "-1 stop" was written `'-1 stop`, read back as `'-1 stop`, and the
    /// operator's own text had grown a character it never had. Worse on a file
    /// NAME, which is a lookup key — a clip called `-take3.mov` filed its
    /// markers and its in/out points under `'-take3.mov` and never found them
    /// again.
    ///
    /// Only an apostrophe in front of one of the four trigger characters is
    /// dropped, because only there can this writer have put one. A value the
    /// operator really did type as `'=x` is the one that cannot round-trip;
    /// escaping that on the way out would change a file post already receives,
    /// so it is left as a known limit rather than fixed here.
    static func unguarded(_ value: String) -> String {
        guard value.hasPrefix("'") else { return value }
        let rest = value.dropFirst()
        guard let first = rest.first, "=+-@".contains(first) else { return value }
        return String(rest)
    }

    private static func escapeQuoting(_ value: String) -> String {
        if value.contains(",") || value.contains("\"")
            || value.contains(where: \.isNewline) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// RFC 4180 parser for ONE line, with the quote state confined to it.
    ///
    /// Still here, and still line-shaped, because it is what the recovery below
    /// needs: a row whose quoting is broken has to be read on its own so that
    /// it costs itself and nothing after it.
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

    /// The whole document, as RECORDS rather than lines.
    ///
    /// A line parser cannot see a quoted field that spans a break, and every
    /// reader here used to split on newlines BEFORE unquoting. That is exactly
    /// the case a card creates: `clip\ntwo.mov` is a legal name on a disk, the
    /// writer quoted it correctly per RFC 4180, and the reader then filed the
    /// marker under `two.mov"` — a name no file has. Breaking the record only
    /// outside the quote state costs nothing and makes what the writer already
    /// emits readable.
    ///
    /// Empty records are dropped, which is what splitting on newlines did: a
    /// blank line in a hand-edited sidecar is not a row.
    static func parseCSVRecords(_ csv: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var index = csv.startIndex
        var recordStart = csv.startIndex
        while index < csv.endIndex {
            let character = csv[index]
            index = csv.index(after: index)
            if inQuotes {
                if character != "\"" {
                    current.append(character)
                } else if index < csv.endIndex, csv[index] == "\"" {
                    current.append("\"")           // an escaped quote
                    index = csv.index(after: index)
                } else {
                    inQuotes = false
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else if character.isNewline {
                fields.append(current)
                current = ""
                if fields != [""] { records.append(fields) }
                fields = []
                recordStart = index
            } else {
                current.append(character)
            }
        }
        // A quote opened and never closed. Reading on would swallow every row
        // after it — these files are hand-edited in Excel and one stray quote
        // must not cost the day's other marks, which is what
        // `anUnterminatedQuoteCostsOnlyItsOwnRow` pins. So from the record that
        // opened it, fall back to reading a line at a time.
        if inQuotes { return records + lineRecords(csv[recordStart...]) }
        fields.append(current)
        if fields != [""] { records.append(fields) }
        return records
    }

    /// The tail of a document that could not be read as records, one line at a
    /// time — the pre-record reading, kept for exactly that recovery.
    private static func lineRecords(_ text: Substring) -> [[String]] {
        text.split(whereSeparator: \.isNewline)
            .map { parseCSVLine(String($0)) }
            .filter { $0 != [""] }
    }
}
