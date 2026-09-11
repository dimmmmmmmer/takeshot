import Foundation

/// **What a dailies folder already holds**, written as the run goes.
///
/// Three of the owner's asks are one file: "не рендерить уже отрендеренное —
/// точно да", "чтоб если софт вылетит можно было продолжить с того же места
/// где упало", and "какая-то у нас проверка типа как после копий была что все
/// файлы точно отрендерены как надо". A run that leaves a note after every
/// item answers all three — the next run skips what is there, a crash costs
/// the item in flight and nothing before it, and a verify pass has a list of
/// what was supposed to be produced to check against.
///
/// It is modelled on `OffloadProgressJournal`, down to the two rules that make
/// that one safe:
///
/// - **written after each item**, because a run that ends the way runs end on
///   set — the machine asleep, the app killed, the disk pulled — never reaches
///   any "finished" step, and a note written only at the end covers exactly
///   the case it exists for and no other;
/// - **nothing in it is TRUSTED.** Every claim is checked against the disk
///   before an item is skipped: the source still has the size and date the
///   entry recorded, the output is still there at the size it was, and the
///   RECIPE still matches. A journal that lied would cost a run the render it
///   would have done anyway.
public struct DailiesJournal: Codable, Sendable, Equatable {
    /// One finished daily.
    public struct Entry: Codable, Sendable, Equatable {
        /// The source's file NAME, not its path: a card is mounted at a
        /// different place every day and the same footage is the same footage.
        public var source: String
        /// What the source was when it was rendered. Size and date together,
        /// because either alone is a coincidence away from wrong: a re-offload
        /// that rewrites the same bytes keeps the size and moves the date, and
        /// a re-render of an edited clip can keep the date and move the size.
        public var sourceSize: Int64
        public var sourceModified: Date
        /// **What this run WAS**, as one string — see `DailiesRecipe`. A daily
        /// made with different burn-ins, a different codec or a different look
        /// is a different deliverable, and skipping it because a file with the
        /// same name is there would quietly ship yesterday's arrangement.
        public var recipe: String
        /// The file it produced, beside this journal.
        public var output: String
        public var outputSize: Int64
        /// **The name the run ASKED for**, which is not always the file it
        /// got: the no-silent-overwrite rule turns a collision into `_2`.
        ///
        /// Recorded separately because it is what a later run compares
        /// against. The affixes around a take's name are the operator's
        /// (`dailies_name_prefix`/`_suffix`), they are not in the recipe, and
        /// without this a day re-rendered under a new suffix would match every
        /// entry it had, skip every item, and produce nothing at all under the
        /// name that was asked for.
        public var outputName: String?
        /// **What the daily WAS when it was written** — how long, and how many
        /// sound tracks. The verify pass has nothing else to hold a file
        /// against: a daily is generated rather than copied, so there is no
        /// source checksum to re-hash the way an offload does. What can be
        /// checked is that the file is still the file that was made — there,
        /// the size it was, as long as it was, with the tracks it had.
        ///
        /// Optional because a journal written before they existed is still a
        /// journal, and an entry that cannot answer is reported as unchecked
        /// rather than as a fault.
        public var outputSeconds: Double?
        public var outputAudio: Int?
        public var finishedAt: Date

        public init(source: String, sourceSize: Int64, sourceModified: Date,
                    recipe: String, output: String, outputSize: Int64,
                    outputName: String? = nil, outputSeconds: Double? = nil,
                    outputAudio: Int? = nil, finishedAt: Date) {
            self.source = source
            self.sourceSize = sourceSize
            self.sourceModified = sourceModified
            self.recipe = recipe
            self.output = output
            self.outputSize = outputSize
            self.outputName = outputName
            self.outputSeconds = outputSeconds
            self.outputAudio = outputAudio
            self.finishedAt = finishedAt
        }
    }

    public var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Add or replace the entry for one source: a folder holds one daily per
    /// source per recipe, and a re-render with the same recipe replaces the
    /// row rather than growing a second one.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.source == entry.source
            && $0.recipe == entry.recipe && $0.outputName == entry.outputName }
        entries.append(entry)
    }

    /// **The daily this item would produce, if the folder already holds it.**
    ///
    /// nil means "render it", and every way of not being sure answers nil:
    /// no entry, a different recipe, a source whose size or date has moved, an
    /// output that is missing or has changed size. The one thing this does NOT
    /// do is open the file — that is the verify pass's job, and doing it here
    /// would put a decode of every finished daily in front of every run.
    public func finished(source: URL, recipe: String, named name: String? = nil,
                         in folder: URL,
                         fileManager: FileManager = .default) -> URL? {
        guard let entry = entries.last(where: {
            $0.source == source.lastPathComponent && $0.recipe == recipe
                // A journal written before this field existed answers nil and
                // is taken at its word: it was written by a run whose names
                // this one cannot compare against, and re-rendering is the
                // safe side of that.
                && (name == nil || $0.outputName == name)
        }) else { return nil }
        guard let current = Self.facts(of: source, fileManager: fileManager),
              current.size == entry.sourceSize,
              abs(current.modified.timeIntervalSince(entry.sourceModified)) < 1
        else { return nil }
        let output = folder.appendingPathComponent(entry.output)
        guard let made = Self.facts(of: output, fileManager: fileManager),
              made.size == entry.outputSize, made.size > 0 else { return nil }
        return output
    }

    /// A file's size and date, or nil when it is not there at all.
    public static func facts(of url: URL, fileManager: FileManager = .default)
        -> (size: Int64, modified: Date)? {
        guard let values = try? fileManager.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date else {
            return nil
        }
        return (size.int64Value, modified)
    }
}

/// Reading and writing the note above.
public enum DailiesProgressJournal {
    /// Beside the dailies themselves, named like the other sidecars this app
    /// leaves next to footage (`takeshot-log.csv`, `takeshot-markers.csv`).
    public static let fileName = "takeshot-dailies.json"

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// The journal in a folder, or an empty one — a folder with no journal is
    /// a folder nothing has been rendered into yet, which is not an error.
    public static func read(in folder: URL) -> DailiesJournal {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let journal = try? JSONDecoder.dailiesJournal
                  .decode(DailiesJournal.self, from: data)
        else { return DailiesJournal() }
        return journal
    }

    /// Atomic, so a journal being written while the machine goes down is
    /// either the old one or the new one and never half of either.
    @discardableResult
    public static func write(_ journal: DailiesJournal,
                             into folder: URL) throws -> URL {
        let destination = url(in: folder)
        let data = try JSONEncoder.dailiesJournal.encode(journal)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

extension JSONEncoder {
    /// ISO dates, sorted keys: the file is read by a person as often as by
    /// this app, and a diff between two days should be the rows that changed.
    static var dailiesJournal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var dailiesJournal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
