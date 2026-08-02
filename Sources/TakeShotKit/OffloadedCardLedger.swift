import Foundation

/// One card the app has stopped asking about, and why.
struct OffloadedCardRecord: Codable, Equatable, Identifiable {
    /// The volume UUID, or its mount path when the filesystem carries none —
    /// see `CardCandidate.key`.
    var key: String
    /// For the settings row that lists what is being kept quiet. A key is a UUID
    /// and says nothing to the operator.
    var name: String
    /// What was on the card when it was offloaded. nil for a card the operator
    /// silenced by hand: `Never` means never, whatever gets shot onto it after.
    var fingerprint: CardFingerprint?
    /// The operator pressed Never, rather than the card having been copied.
    var suppressed: Bool
    var date: Date

    var id: String { key }
}

/// Which cards must not be offered again.
///
/// **Why not part of the offload history.** They answer different questions over
/// different lifetimes. The history is the last twenty runs, capped because past
/// that nobody reads it; this is a set with no natural size, and its entire
/// purpose is to outlive that window — a card offloaded twenty-one runs ago must
/// still not be offered when it comes back out of a case. Folding the two
/// together would mean either truncating this with the list (the bug) or
/// uncapping the list (a scrolling wall nobody reads). Same folder, same
/// best-effort write, its own file.
@MainActor
final class OffloadedCardLedger: ObservableObject {
    @Published private(set) var cards: [OffloadedCardRecord] = []

    /// A `var` for the reason `OffloadHistoryStore.fileURL` is one: a test must
    /// not read or write the operator's real Application Support, and the suite
    /// points this at its own scratch folder.
    var fileURL: URL = OffloadedCardLedger.defaultURL {
        didSet { load() }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TakeShot/offloaded-cards.json")
    }

    /// A file that will not decode is treated as an empty ledger, like the
    /// history's own load: the cost is one prompt too many, and refusing to run
    /// the watch over a stale JSON blob would be the tail wagging the dog.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([OffloadedCardRecord].self,
                                                     from: data)
        else {
            cards = []
            return
        }
        cards = stored
    }

    func record(for key: String) -> OffloadedCardRecord? {
        cards.first { $0.key == key }
    }

    /// Has this card already been dealt with?
    ///
    /// A silenced card is silenced whatever is on it. An offloaded one is only
    /// skipped while it still holds exactly what was copied — a card that has
    /// been shot on since IS offered again, which is the whole reason the
    /// fingerprint is stored beside the key.
    func isSettled(_ candidate: CardCandidate) -> Bool {
        guard let record = record(for: candidate.key) else { return false }
        if record.suppressed { return true }
        return record.fingerprint == candidate.fingerprint
    }

    /// The card was copied, verified and is now accounted for.
    func markOffloaded(_ candidate: CardCandidate, at date: Date = Date()) {
        store(OffloadedCardRecord(key: candidate.key, name: candidate.name,
                                  fingerprint: candidate.fingerprint,
                                  suppressed: false, date: date))
    }

    /// The operator pressed Never. No fingerprint: this card is done being asked
    /// about, however much footage lands on it later.
    func suppress(_ candidate: CardCandidate, at date: Date = Date()) {
        store(OffloadedCardRecord(key: candidate.key, name: candidate.name,
                                  fingerprint: nil, suppressed: true,
                                  date: date))
    }

    /// Start offering THIS card again. The way back from a mis-clicked Never,
    /// which is otherwise permanent — and a permanent, invisible, unreachable
    /// decision taken by one click is not a decision an app should be able to
    /// impose.
    ///
    /// One card at a time rather than a "forget everything" button (owner item
    /// 18): the operator who wants to be asked about one disk again should not
    /// have to re-answer for every card of the shoot to get it. Nothing calls
    /// this directly — `CaptureController.forgetOffloadedCard` does, because
    /// the session's own copy of the decision has to go with it.
    func forget(_ key: String) {
        cards.removeAll { $0.key == key }
        save()
    }

    private func store(_ record: OffloadedCardRecord) {
        cards.removeAll { $0.key == record.key }
        cards.append(record)
        save()
    }

    /// Best-effort, like the history's: losing this file costs the operator a
    /// repeated prompt, not a fact about footage, and an alarm raised over a
    /// read-only Application Support folder would be a false one.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(cards) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
