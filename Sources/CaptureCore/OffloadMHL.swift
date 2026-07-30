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
    static func escaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
