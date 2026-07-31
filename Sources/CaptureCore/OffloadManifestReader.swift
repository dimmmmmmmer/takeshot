import Foundation

/// What one ASC MHL manifest claims: which checksum it was written with, and
/// every file it lists.
///
/// The counterpart of `OffloadMHL`, which writes them. Kept as a value rather
/// than parsed on the fly because the verify pass reads it once and then walks
/// it twice — once to re-hash what it lists, once to work out what is on the
/// disk that it does NOT list.
public struct OffloadManifest: Sendable, Equatable {
    public let url: URL
    public let algorithm: OffloadHashAlgorithm
    public let entries: [OffloadEntry]

    public init(url: URL, algorithm: OffloadHashAlgorithm,
                entries: [OffloadEntry]) {
        self.url = url
        self.algorithm = algorithm
        self.entries = entries
    }
}

/// Why a folder cannot be checked at all — as opposed to checking it and finding
/// something wrong, which is a report rather than an error.
///
/// English, like the rest of CaptureCore. The app maps the first case to its own
/// localized sentence, because "this folder was never offloaded by anything" is
/// the one an operator hits by picking the wrong folder and has to understand
/// immediately; the rest are rare and technical and travel as they are.
public enum OffloadVerifyError: LocalizedError, Equatable {
    /// No `ascmhl/` folder, or nothing in it — not an offload destination.
    case noManifest(String)
    /// There is a manifest and it will not parse.
    case unreadableManifest(name: String, reason: String)
    /// It parses, and its checksums are ones this build cannot compute (an
    /// `ascmhl` manifest written with MD5 or C4, say). Refused whole rather than
    /// verified in part: a report that silently skipped half the card would be
    /// read as a clean bill of health for all of it.
    case unsupportedHash(name: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .noManifest(let folder):
            return "no ASC MHL manifest in \(folder)"
        case .unreadableManifest(let name, let reason):
            return "\(name) could not be read: \(reason)"
        case .unsupportedHash(let name, let found):
            return "\(name) uses a checksum TakeShot cannot compute (\(found))"
        }
    }
}

/// Finding and parsing the manifests `OffloadMHL` writes.
public enum OffloadManifestReader {
    /// The manifest that describes this tree as it stands now.
    ///
    /// ASC MHL numbers manifests oldest first and keeps every generation, so a
    /// folder offloaded to twice holds `0001_…` and `0002_…` and only the
    /// highest one lists what is actually there. Verifying against the first
    /// would report every file added by the second run as a stray.
    public static func latest(in root: URL) -> URL? {
        let folder = root.appendingPathComponent(OffloadMHL.folderName,
                                                 isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == OffloadMHL.fileExtension }
            .max { generation(of: $0) < generation(of: $1) }
    }

    /// The leading number in `0002_A001_2026-07-30_143102.mhl`, with the name as
    /// a tiebreak so the ordering is total. A manifest whose name does not start
    /// with digits (one another tool wrote) sorts below every numbered one
    /// rather than being dropped — it is still a manifest, it just cannot claim
    /// to be the newest generation on the strength of its name.
    static func generation(of url: URL) -> (Int, String) {
        let name = url.lastPathComponent
        return (Int(name.prefix { $0.isNumber }) ?? -1, name)
    }

    /// Parse a manifest.
    ///
    /// `XMLParser` rather than `XMLDocument`: a card of ten thousand files is a
    /// manifest of ten thousand elements, and the streaming parser reads it
    /// without building a tree of the whole thing first.
    public static func read(_ url: URL) throws -> OffloadManifest {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OffloadVerifyError.unreadableManifest(
                name: name, reason: error.localizedDescription)
        }
        let reader = HashListReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            throw OffloadVerifyError.unreadableManifest(
                name: name,
                reason: parser.parserError?.localizedDescription ?? "malformed XML")
        }
        if !reader.unusable.isEmpty {
            throw OffloadVerifyError.unsupportedHash(
                name: name,
                found: reader.unusable.sorted().joined(separator: ", "))
        }
        guard let algorithm = reader.algorithm, !reader.entries.isEmpty else {
            throw OffloadVerifyError.noManifest(name)
        }
        return OffloadManifest(url: url, algorithm: algorithm,
                               entries: reader.entries)
    }
}

/// The `<hashlist>` document, read as a stream of events.
///
/// Only `<hash>` blocks matter: a `<path size="…">` and one or more digest
/// elements named after the algorithm that produced them. `creatorinfo` and
/// `processinfo` are for whoever opens the file, not for us.
private final class HashListReader: NSObject, XMLParserDelegate {
    private(set) var entries: [OffloadEntry] = []
    /// The algorithm the first entry was verified with; every later entry is
    /// read with the same one where it offers a choice.
    private(set) var algorithm: OffloadHashAlgorithm?
    /// Digest element names found on entries this build cannot compute.
    private(set) var unusable: Set<String> = []

    private var inHash = false
    private var path: String?
    private var size: Int64 = 0
    /// Every digest of the current entry, by element name. ASC MHL allows more
    /// than one, and picking whichever the dictionary hands back first would
    /// make the choice depend on hash order rather than on anything real.
    private var digests: [String: String] = [:]
    private var text = ""

    /// Namespaces are left off (`shouldProcessNamespaces` defaults to false), so
    /// a manifest written with a prefix arrives as `mhl:hash`. Ours are written
    /// with a default namespace and no prefix; both reduce to the same name.
    private static func localName(_ element: String) -> String {
        String(element.split(separator: ":").last ?? "").lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        text = ""
        switch Self.localName(element) {
        case "hash":
            inHash = true
            path = nil
            size = 0
            digests = [:]
        case "path" where inHash:
            size = Int64(attributes["size"] ?? "") ?? 0
        default:
            break
        }
    }

    /// Character data arrives in as many pieces as the parser feels like, so it
    /// is accumulated rather than assigned — a hash split across two callbacks
    /// would otherwise come out as its own last few characters.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(element)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard inHash else { return }
        switch name {
        case "hash":
            inHash = false
            finishEntry()
        case "path":
            path = value
        default:
            if !value.isEmpty { digests[name] = value }
        }
    }

    private func finishEntry() {
        guard let path, !path.isEmpty, !digests.isEmpty else { return }
        guard let (used, digest) = pick() else {
            unusable.formUnion(digests.keys)
            return
        }
        algorithm = algorithm ?? used
        entries.append(OffloadEntry(relativePath: path, size: size, hash: digest))
    }

    /// One digest per entry, and the same algorithm throughout: whichever one
    /// the manifest has already been read with wins, so a file that carries both
    /// an xxh64 and a sha256 is not the one that quietly switches the run to the
    /// slower hash halfway down the card.
    private func pick() -> (OffloadHashAlgorithm, String)? {
        var order = OffloadHashAlgorithm.allCases
        if let algorithm {
            order = [algorithm] + order.filter { $0 != algorithm }
        }
        for candidate in order {
            if let digest = digests[candidate.manifestElement] {
                return (candidate, digest)
            }
        }
        return nil
    }
}
