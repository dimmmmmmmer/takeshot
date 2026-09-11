import Foundation

/// **What a folder of the sound recordist's files offers a dailies run**
/// (owner: "было бы классно иметь возможность выбрать папку со звуком — типа
/// если у звука и тейков одинаковые таймкоды, чтоб он автоматически подружил
/// нужные тейки").
///
/// The same shape as `DailiesSourceScan` and for the same reason: the honest
/// answer for a folder is not "every wav in it". A file with no `bext` chunk
/// carries no timecode, so nothing can line it up with a take — and an
/// operator who pointed at the wrong folder has to be told that BEFORE a
/// forty-item run produces forty silent dailies.
public enum DailiesSoundScan {
    /// What a recordist's delivery is written as. `.bwf` is the same format
    /// under a name some units use.
    public static let readable: Set<String> = ["wav", "bwf"]

    public struct Findings: Sendable, Equatable {
        /// Files that can be matched: they read, and they carry a start.
        public var files: [BroadcastWaveFacts] = []
        /// Read, but with no `bext` timecode — nothing can be done with them,
        /// and the operator is told rather than left with a silent daily.
        public var withoutTimecode: [URL] = []
        /// Would not read at all (not a WAVE, no `fmt `, unreadable).
        public var unreadable: [URL] = []

        public var isEmpty: Bool {
            files.isEmpty && withoutTimecode.isEmpty && unreadable.isEmpty
        }

        public init(files: [BroadcastWaveFacts] = [],
                    withoutTimecode: [URL] = [], unreadable: [URL] = []) {
            self.files = files
            self.withoutTimecode = withoutTimecode
            self.unreadable = unreadable
        }
    }

    /// Walk `folder` for sound. Recursive and hidden-file-skipping, like the
    /// footage walk: a day's sound delivery is a tree of scene folders as
    /// often as it is flat.
    public static func scan(_ folder: URL) -> Findings {
        var findings = Findings()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return findings }
        for case let url as URL in walker {
            guard readable.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true else { continue }
            guard let facts = try? BroadcastWaveReader.read(url) else {
                findings.unreadable.append(url)
                continue
            }
            if facts.startSecondsSinceMidnight == nil {
                findings.withoutTimecode.append(url)
            } else {
                findings.files.append(facts)
            }
        }
        findings.files.sort { $0.url.path < $1.url.path }
        findings.withoutTimecode.sort { $0.path < $1.path }
        findings.unreadable.sort { $0.path < $1.path }
        return findings
    }

    /// Every folder's findings, merged, a file counted once — two folders may
    /// overlap (the recordist's card and the copy on the shuttle), and the
    /// same sound laid in twice is two copies of the boom on one daily.
    public static func scan(_ folders: [URL]) -> Findings {
        var merged = Findings()
        var seen: Set<String> = []
        for folder in folders {
            let found = scan(folder)
            for facts in found.files where seen.insert(facts.url.path).inserted {
                merged.files.append(facts)
            }
            for url in found.withoutTimecode where seen.insert(url.path).inserted {
                merged.withoutTimecode.append(url)
            }
            for url in found.unreadable where seen.insert(url.path).inserted {
                merged.unreadable.append(url)
            }
        }
        return merged
    }
}
