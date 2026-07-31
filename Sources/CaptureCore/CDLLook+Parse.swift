import Foundation

/// Reading ASC CDL files: `.cc` (a bare `ColorCorrection`), `.ccc` (a
/// `ColorCorrectionCollection`) and `.cdl` (a `ColorDecisionList` wrapping each
/// correction in a `ColorDecision`).
///
/// One reader for all three, because they differ only in what is wrapped around
/// the `ColorCorrection` element — the grade itself is identical in each, and
/// three parsers would be three chances for `.cdl` and `.ccc` to disagree about
/// the same nine numbers.
extension CDLLook {
    public enum ParseError: Error, LocalizedError, Equatable {
        case malformedXML(String)
        case noColorCorrection

        public var errorDescription: String? {
            switch self {
            case .malformedXML(let detail):
                return "ASC CDL: the file is not valid XML — \(detail)"
            case .noColorCorrection:
                return "ASC CDL: no ColorCorrection found — is this a .cc/.ccc/.cdl?"
            }
        }
    }

    /// The extensions this reader claims.
    public static let fileExtensions = ["cdl", "ccc", "cc"]

    /// The look in a file.
    ///
    /// A collection may hold several corrections; the first is taken, because a
    /// look is one grade and there is nowhere in the app to choose between
    /// them. The rest are reachable through `looks(in:)` when there is.
    public static func load(url: URL) throws -> CDLLook {
        let text = try String(contentsOf: url, encoding: .utf8)
        var look = try looks(in: text)[0]
        if look.id.isEmpty {
            look.id = url.deletingPathExtension().lastPathComponent
        }
        return look
    }

    /// Every `ColorCorrection` in the text, in document order. Never empty —
    /// a file with none throws rather than yielding a silent identity grade,
    /// which would look exactly like a look that does nothing.
    public static func looks(in text: String) throws -> [CDLLook] {
        let reader = CDLXMLReader()
        let parser = XMLParser(data: Data(text.utf8))
        // ASC CDL files carry xmlns="urn:ASC:CDL:v1.01", and tools in the wild
        // also write it prefixed (cdl:ColorCorrection). Processing namespaces
        // makes the delegate see the local name in both cases.
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else {
            throw ParseError.malformedXML(
                parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard !reader.looks.isEmpty else { throw ParseError.noColorCorrection }
        return reader.looks
    }
}

/// The SAX side of the reader. A class because `XMLParser` wants a delegate;
/// it never leaves the call that makes it, so it needs no synchronization.
private final class CDLXMLReader: NSObject, XMLParserDelegate {
    private(set) var looks: [CDLLook] = []
    /// The correction being read. Nil between corrections, which is what makes
    /// a stray `<Slope>` outside one a no-op instead of a crash.
    private var current: CDLLook?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        text = ""
        guard elementName == "ColorCorrection" else { return }
        // every field starts at the identity, so a file that omits SatNode (or
        // any SOP node) reads as "this grade does not touch that" rather than
        // as zero — a missing Saturation defaulting to 0 is a greyscale picture
        current = CDLLook(id: attributeDict["id"] ?? "")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text
        text = ""
        guard var look = current else { return }
        switch elementName {
        case "Slope": look.slope = Self.triple(value) ?? look.slope
        case "Offset": look.offset = Self.triple(value) ?? look.offset
        case "Power": look.power = Self.triple(value) ?? look.power
        case "Saturation": look.saturation = Self.number(value) ?? look.saturation
        case "ColorCorrection":
            looks.append(look)
            current = nil
            return
        default: return
        }
        current = look
    }

    /// "1.0 1.02 0.98" — the three channel values of a SOP node. Separators are
    /// any whitespace: files in the wild wrap the triple over three lines.
    private static func triple(_ text: String) -> CDLLook.RGB? {
        let parts = text.split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return CDLLook.RGB(parts[0], parts[1], parts[2])
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
