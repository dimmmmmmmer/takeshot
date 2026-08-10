import Foundation

/// The ASC MHL manifest an offload leaves in each destination.
///
/// This is the file that makes the copy verifiable by somebody else: post drops
/// the SSD on a machine running Pomfort's `ascmhl`, Silverstack or OffShoot,
/// points it at the folder and re-computes every hash weeks later. So the shape
/// follows the ASC Media Hash List v2 hashlist document rather than anything
/// convenient for us:
///
/// - the manifest lives in an `ascmhl/` folder at the root of the copied tree,
///   and every `<path>` is relative to that root;
/// - manifests are numbered, oldest first, so a folder that is offloaded to
///   twice keeps both generations instead of losing the first;
/// - `creatorinfo` names the tool, its version and the machine — the three
///   things anybody investigating a bad file asks for first.
///
/// Not written: the `ascmhl_chain.xml` chain file, which only matters once a
/// folder is managed by repeated ascmhl operations, and the optional root hash.
public enum OffloadMHL {
    /// Where ASC MHL keeps manifests, and the name every tool looks for.
    ///
    /// Not a choice of ours and not one to revisit (owner item 24): the receipt
    /// a person reads is in the root of the copy, but this file is read by
    /// `ascmhl`, Silverstack and OffShoot, and all three look in `ascmhl/`.
    /// Moved to the root it would simply never be found.
    public static let folderName = "ascmhl"
    public static let fileExtension = "mhl"

    /// Write the manifest for `entries` into `destination`, returning its URL.
    public static func write(entries: [OffloadEntry], into destination: URL,
                             algorithm: OffloadHashAlgorithm,
                             creator: OffloadCreatorInfo,
                             date: Date) throws -> URL {
        let folder = destination.appendingPathComponent(folderName,
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let url = CapturePipeline.uniqueURL(for: folder.appendingPathComponent(
            fileName(in: folder, root: destination, date: date)))
        defer { CapturePipeline.releaseReservation(for: url) }
        let document = xml(entries: entries, algorithm: algorithm,
                          creator: creator, date: date)
        try Data(document.utf8).write(to: url, options: .atomic)
        return url
    }

    /// `0002_A001_2026-07-30_143102.mhl` — the generation, the folder it
    /// describes, and when it was made.
    static func fileName(in folder: URL, root: URL, date: Date) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == fileExtension }.count ?? 0
        let name = safeName(root.lastPathComponent)
        return String(format: "%04d_%@_%@.%@", existing + 1, name,
                      OffloadFormat.fileStamp(date), fileExtension)
    }

    /// The folder name goes into a file name, so anything a path separator or a
    /// shell would choke on is replaced rather than escaped.
    private static func safeName(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character.isLetter || character.isNumber || "-_.".contains(character)
                ? character : "_"
        }
        let joined = String(cleaned)
        return joined.isEmpty ? "offload" : joined
    }

    /// The hashlist document.
    public static func xml(entries: [OffloadEntry],
                           algorithm: OffloadHashAlgorithm,
                           creator: OffloadCreatorInfo, date: Date) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">",
            "  <creatorinfo>",
            "    <creationdate>\(OffloadFormat.iso8601(date))</creationdate>",
            "    <hostname>\(escaped(creator.hostname))</hostname>",
            "    <tool version=\"\(escaped(creator.toolVersion))\">"
                + "\(escaped(creator.toolName))</tool>",
            "  </creatorinfo>",
            "  <processinfo>",
            // A copy from a card to a destination is a transfer, as opposed to
            // hashing a folder in place or flattening one.
            "    <process>transfer</process>",
            "  </processinfo>",
            "  <hashes>",
        ]
        for entry in entries {
            lines += hashElement(entry, algorithm: algorithm)
        }
        lines += ["  </hashes>", "</hashlist>", ""]
        return lines.joined(separator: "\n")
    }

    /// `action="original"`: this is the first manifest of this destination tree,
    /// so its hashes are that tree's originals. That they were also checked
    /// against the card is what the summary next to it is for — MHL has no
    /// vocabulary for "verified against a different volume".
    private static func hashElement(_ entry: OffloadEntry,
                                    algorithm: OffloadHashAlgorithm) -> [String] {
        ["    <hash>",
         "      <path size=\"\(entry.size)\">\(escaped(entry.relativePath))</path>",
         "      <\(algorithm.manifestElement) action=\"original\">"
            + "\(entry.hash)</\(algorithm.manifestElement)>",
         "    </hash>"]
    }

    /// Both element text and attribute values go through this — a file called
    /// `A&B <take 2>.mov` is legal on a card and would otherwise produce a
    /// manifest no parser will open.
    ///
    /// Two things beyond the five predefined entities, both of them measured
    /// against `XMLParser` on a manifest this writer had just produced:
    ///
    /// - **A carriage return has to be a character reference.** XML end-of-line
    ///   normalization rewrites a literal CR as LF before the document ever
    ///   reaches a parser's client, so `clip\rtwo.mov` was written faithfully
    ///   and read back as `clip\ntwo.mov` — a name no file has, which the verify
    ///   pass then reports as one file missing and another one extra.
    /// - **A character XML 1.0 does not allow at all is replaced.** NUL, BEL,
    ///   VT, FF and the rest of the C0 range are legal in a POSIX file name and
    ///   illegal in an XML document; one of them anywhere on the card made the
    ///   whole manifest unparseable (`unreadableManifest`), so the entire copy
    ///   became unverifiable rather than the one file. There is no escape for
    ///   them — a numeric reference to a forbidden character is forbidden too —
    ///   so U+FFFD goes in and that single entry mismatches, loudly, while
    ///   every other file on the card still verifies.
    static func escaped(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            case "\r": escaped += "&#13;"
            default:
                escaped.unicodeScalars.append(isLegalXML10(scalar)
                    ? scalar : "\u{FFFD}")
            }
        }
        return escaped
    }

    /// The `Char` production of XML 1.0 fifth edition: tab, LF, CR, then
    /// everything from U+0020 up bar the surrogates and the two noncharacters
    /// at the end of the BMP.
    private static func isLegalXML10(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }
}
