import CaptureCore
import Foundation

/// State of the offload sheet, and the run it drives.
///
/// Owned by the controller rather than by the view: the run outlives any
/// particular render of the sheet, and the takes-panel status line reads from it
/// too. Panels (`NSOpenPanel`) deliberately do NOT live here — that keeps the
/// whole engine-facing side of the sheet reachable from a test.
@MainActor
final class OffloadSheetModel: ObservableObject {
    /// One destination row. Its identity is its own, not its URL's: while the
    /// operator is still picking, two rows can legitimately hold the same
    /// folder, and a URL-keyed list would collapse them.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var url: URL
    }

    /// The checksum every run uses.
    ///
    /// A constant, not a setting. The picker that used to be on the sheet asked
    /// the operator a question they cannot answer on set — xxHash64 is what
    /// every DIT tool (Silverstack, OffShoot, ascmhl) verifies against, and
    /// SHA-256 is several times slower for a guarantee nobody downstream asked
    /// for. The ENGINE stays capable of both, and a manifest written in either
    /// still verifies (see `OffloadManifestReader`); what went is the question.
    static let algorithm: OffloadHashAlgorithm = .xxh64

    /// The cards to copy, in the order they will be copied.
    ///
    /// A LIST rather than one folder (owner: "вот выбор папок для копирования —
    /// давай сделаем как во втором блоке. вариант добавлять несколько папок и
    /// удалять из списка"). A shooting day is several cards and several sound
    /// rolls, and the sheet used to make that several separate runs — each one
    /// a wait at the machine before the next could be started.
    ///
    /// The cards are copied ONE AT A TIME, each with its own report and its own
    /// manifest. That is not a limitation: a manifest is per card by
    /// convention, it is what every downstream tool verifies against, and a
    /// card that failed has to be identifiable as the card that failed rather
    /// than as part of a batch.
    @Published var sourceRows: [Row] = []
    @Published var rows: [Row] = []
    /// Live state of the run; nil when nothing is running.
    @Published var progress: OffloadProgress?
    /// The last finished run. Set by the run, and by the view-render tests,
    /// which have to be able to draw every result state without a disk.
    @Published var report: OffloadReport?
    @Published var isRunning = false
    /// Cancel has been pressed: the file in flight finishes, then the run stops.
    @Published var isCancelling = false
    /// What the destinations already hold from an interrupted run of this card,
    /// waiting for the operator's answer. nil means there is nothing to answer —
    /// either no destination holds one, or the question has been answered.
    ///
    /// A run that skips files is a run the operator agreed to skip them in. The
    /// engine's own comment says a skipped folder is how footage goes missing;
    /// this is that rule applied to the feature whose whole job is skipping.
    @Published var resumeReview: OffloadResumeReview?
    /// The survey is out. It walks the card, so it is off the main thread, and
    /// Start is not offered again until it comes back.
    @Published var isSurveying = false

    /// Every finished card's report, oldest first. The sheet lists them; the
    /// last one is also `report`, which is what the single-card UI reads.
    @Published var reports: [OffloadReport] = []
    /// Which card is being copied, 1-based, and how many the run has. Both 0
    /// when nothing is running. The status line says "card 2 of 3" from these,
    /// and says nothing extra when there is only one — the ordinary case.
    @Published var cardIndex = 0
    @Published var cardCount = 0

    /// The cards still to copy. The one in flight is NOT in here; it is
    /// `currentSource`, which is what the report and the manifest are about.
    private var remainingSources: [URL] = []
    private(set) var currentSource: URL?
    /// Cancel was pressed while the survey was still out. The survey itself
    /// cannot be stopped — it is one manifest parse per destination — but its
    /// answer must not start a copy.
    private var queueCancelled = false

    /// Stamped into every manifest.
    var creator: OffloadCreatorInfo = .current()
    private var cancellation: OffloadCancellation?
    private weak var controller: CaptureController?

    var destinations: [URL] { rows.map(\.url) }
    var sources: [URL] { sourceRows.map(\.url) }

    /// Wired once, in `CaptureController.init`, rather than when the sheet
    /// opens: a run reports through the controller (status line, toast, sticky
    /// alarm), and a model that only got its controller on the way through the
    /// UI would run perfectly silently if it were ever started another way.
    func attach(to controller: CaptureController) {
        self.controller = controller
    }

    /// Seed from the operator's saved rig and clear the previous run's result —
    /// a stale "verified" card on top of a sheet opened for the next card is a
    /// dangerous thing to leave lying around.
    func prepare(settings: CaptureSettings, version: String) {
        creator = .current(version: version)
        if !isRunning {
            progress = nil
            report = nil
            reports = []
            isCancelling = false
            resumeReview = nil
        }
        guard rows.isEmpty else { return }
        // The operator's saved destination list. The folder the retired verified
        // backup used to hold is in it too — `CaptureSettings.migrateToVersion2`
        // moves it there on load, so nobody loses a path they had chosen.
        let saved = settings.offload.destinationPaths ?? []
        rows = saved.map { Row(url: URL(fileURLWithPath: $0)) }
    }

    // MARK: - editing the card list

    /// Queue a card. Already queued — nothing happens, because the second copy
    /// of one card into one destination is a name collision, not a plan.
    func addSource(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !sources.contains(where: { $0.standardizedFileURL.path == path })
        else { return }
        sourceRows.append(Row(url: url))
    }

    func setSource(_ url: URL, at id: Row.ID) {
        guard let index = sourceRows.firstIndex(where: { $0.id == id })
        else { return }
        sourceRows[index].url = url
    }

    func removeSource(_ id: Row.ID) {
        sourceRows.removeAll { $0.id == id }
    }

    // MARK: - editing the destination list

    func addDestination(_ url: URL) {
        rows.append(Row(url: url))
        rememberDestinations()
    }

    func setDestination(_ url: URL, at id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].url = url
        rememberDestinations()
    }

    func removeDestination(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
        rememberDestinations()
    }

    /// The saved rig follows the LIST, not the run.
    ///
    /// It used to be written from `begin(resume:)` alone, and that path is only
    /// reachable with a non-empty list — so `offload.destinationPaths` could
    /// never become nil again and a removal had nowhere to be recorded. Two
    /// things then outlived the destination: the sheet seeded the retired path
    /// back in on the next open, and `ownFolders` went on excluding that
    /// destination's whole volume from the mounted-card offers, which is the
    /// half that costs footage rather than a click.
    private func rememberDestinations() {
        controller?.rememberOffloadChoices(destinations: destinations)
    }

    /// Where a row's copy actually lands: the card's own folder name, created
    /// inside the chosen destination. Three SSDs then hold three folders named
    /// after the card rather than three loose DCIM trees.
    func destinationFolder(for row: Row, card: URL) -> URL {
        row.url.appendingPathComponent(card.lastPathComponent)
    }

    /// Where one card lands, on every destination.
    func destinationFolders(for card: URL) -> [URL] {
        rows.map { destinationFolder(for: $0, card: card) }
    }

    /// Every folder this run will write, over every card. What the validation
    /// reasons about, and what the resume survey would have to ask about.
    var allDestinationFolders: [URL] {
        sources.flatMap { destinationFolders(for: $0) }
    }

    /// What "show it in the Finder" opens for a row (owner item 23): the copy's
    /// own folder once it exists, and the disk the operator chose before that.
    ///
    /// A run that has not started has no card folder yet, and a button that
    /// does nothing until the copy is under way is one the operator stops
    /// trying. During and after the run it opens the copy itself, which is
    /// what they are actually asking to look at.
    func finderTarget(for row: Row) -> URL {
        // With several cards queued there is no single folder to open — the
        // destination itself holds all of them, which is the thing to look at.
        guard sources.count == 1, let card = sources.first else { return row.url }
        let folder = destinationFolder(for: row, card: card)
        guard FileManager.default.fileExists(atPath: folder.path)
        else { return row.url }
        return folder
    }

    // MARK: - validation

    /// Why the run cannot start, in the operator's language. nil means either
    /// "ready" or "nothing chosen yet" — the button's own disabled state covers
    /// the second case without shouting about it.
    var validationMessage: String? {
        let folders = destinations
        if Set(folders.map(\.standardizedFileURL.path)).count != folders.count {
            return L("offload_error_duplicate")
        }
        // Two cards with the SAME NAME land in one folder on the destination
        // and overwrite each other. `addSource` refuses the same card twice,
        // but two different paths can still end in "A001" — two rigs, two
        // days, one careless label — and that one is worth saying out loud
        // rather than discovering in the manifest.
        let names = sources.map(\.lastPathComponent)
        if Set(names).count != names.count {
            return L("offload_error_same_name")
        }
        for card in sources.map(\.standardizedFileURL) {
            for folder in destinationFolders(for: card).map(\.standardizedFileURL)
            where folder == card || folder.path.hasPrefix(card.path + "/") {
                // Copying a tree into itself grows forever and can never verify.
                return L("offload_error_nested")
            }
        }
        return nil
    }

    var canStart: Bool {
        !isRunning && !isSurveying && resumeReview == nil && !sourceRows.isEmpty
            && !rows.isEmpty && validationMessage == nil
    }

    // MARK: - resuming an interrupted run

    /// Start, which now means: ask the destinations what they already hold, and
    /// only run once that question has an answer.
    ///
    /// The survey is cheap — one manifest parse per destination — but it walks
    /// the card to compare paths and sizes, so it goes on the offload queue.
    /// When nothing is reusable it runs straight through, which is every
    /// ordinary card.
    func start() {
        guard canStart else { return }
        // The whole queue is fixed here, at the press: a list edited while the
        // run is going would otherwise change what "card 2 of 3" means halfway
        // through, and the sheet's controls are disabled for exactly as long
        // as this queue lasts.
        remainingSources = sources
        queueCancelled = false
        cardCount = remainingSources.count
        cardIndex = 0
        reports = []
        report = nil
        surveyNextCard()
    }

    /// Take the next card off the queue and ask the destinations what they
    /// already hold of it. Nothing left — the run is done.
    private func surveyNextCard() {
        guard !remainingSources.isEmpty else {
            finishQueue()
            return
        }
        let source = remainingSources.removeFirst()
        currentSource = source
        cardIndex += 1
        isSurveying = true
        controller?.offloadStatus = L("offload_resume_checking")
        let folders = destinationFolders(for: source)
        // Read on the main actor and sent in: `algorithm` is main-actor state,
        // and reaching for it from inside the Sendable closure is the race the
        // Swift 6 mode exists to catch.
        let algorithm = Self.algorithm
        CaptureController.offloadQueue.async { [weak self] in
            let review = OffloadResume.review(source: source,
                                              destinations: folders,
                                              algorithm: algorithm)
            DispatchQueue.main.async { self?.answer(review) }
        }
    }

    /// The survey is back. Something to reuse means a question; nothing to reuse
    /// means the run the operator already asked for.
    private func answer(_ review: OffloadResumeReview) {
        isSurveying = false
        // Cancelled while the survey was out: nothing has been copied for this
        // card and nothing is going to be.
        guard !queueCancelled else {
            finishQueue()
            return
        }
        guard review.isUsable else {
            begin(resume: false)
            return
        }
        resumeReview = review
        controller?.offloadStatus = nil
    }

    /// Reuse what is already there — each file re-read off the disk and hashed
    /// against that disk's own manifest before it is trusted.
    func resumeRun() {
        resumeReview = nil
        begin(resume: true)
    }

    /// Copy the whole card again. The way out of a resume the operator does not
    /// trust, and the reason the question is a question.
    func copyEverything() {
        resumeReview = nil
        begin(resume: false)
    }

    // MARK: - the run

    private func begin(resume: Bool) {
        guard let source = currentSource, !isRunning else { return }
        // The report labels are read here, once, in the operator's current UI
        // language: the summary and the card of THIS run speak one language
        // even if the switch is flipped while it copies (owner item 21).
        let plan = OffloadPlan(source: source,
                               destinations: destinationFolders(for: source),
                               algorithm: Self.algorithm, creator: creator,
                               resume: resume, reportLabels: .current())
        let token = OffloadCancellation()
        cancellation = token
        isRunning = true
        isCancelling = false
        progress = nil
        report = nil
        controller?.rememberOffloadChoices(destinations: destinations)
        controller?.offloadStatus = L("offload_scanning")
        CaptureController.offloadQueue.async { [weak self] in
            let result = OffloadEngine.run(plan, cancellation: token) { snapshot in
                DispatchQueue.main.async { self?.apply(snapshot) }
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    /// Safe cancel: the flag is read between files, so what is on the
    /// destination is always a whole file, and the summary records where it
    /// stopped.
    /// Stop — the card in flight after the file it is on, and every card
    /// behind it.
    ///
    /// The whole queue, not just the current card: cancel means "stop
    /// copying", and a run that went quiet and then started the next card by
    /// itself would be the opposite of what was asked — with the operator
    /// having pulled the disk on the strength of it.
    ///
    /// It works during the SURVEY too. The survey cannot itself be stopped (one
    /// manifest parse per destination, already in flight), but on a full card
    /// with three destinations it is long enough to be pressed through, and a
    /// Cancel that did nothing there would be a Cancel the operator learns not
    /// to trust.
    func cancel() {
        guard isRunning || isSurveying else { return }
        remainingSources = []
        queueCancelled = true
        guard isRunning else {
            controller?.offloadStatus = L("offload_cancelling")
            return
        }
        cancellation?.cancel()
        isCancelling = true
        controller?.offloadStatus = L("offload_cancelling")
    }

    private func apply(_ snapshot: OffloadProgress) {
        guard isRunning else { return }
        progress = snapshot
        guard !isCancelling else { return }
        let done = snapshot.destinations.map(\.filesDone).max() ?? 0
        let line = L("offload_progress", done, snapshot.filesTotal)
        controller?.offloadStatus = cardCount > 1
            ? L("offload_card_of", cardIndex, cardCount) + " · " + line
            : line
    }

    /// One card is done. Logged, reported, and then the next one starts.
    ///
    /// Every card goes through `offloadDidFinish` on its own: its own history
    /// entry, its own verified-card note, and — the half that matters — its own
    /// sticky alarm the moment it fails, rather than at the end of a queue that
    /// may still have twenty minutes to run.
    private func finish(_ result: OffloadReport) {
        isRunning = false
        isCancelling = false
        progress = nil
        report = result
        reports.append(result)
        cancellation = nil
        controller?.offloadDidFinish(result)
        // A cancelled card cancels the queue: `cancel()` has already emptied
        // it, and a card that stopped on its own (a source that went away
        // mid-copy) is not a reason to walk on to the next one silently.
        guard !result.wasCancelled else {
            finishQueue()
            return
        }
        surveyNextCard()
    }

    /// The queue is empty. Says how many cards were copied when there was more
    /// than one — `offloadDidFinish` has already spoken for the last card, and
    /// on a batch that line describes a third of what happened.
    private func finishQueue() {
        currentSource = nil
        isSurveying = false
        queueCancelled = false
        controller?.offloadStatus = nil
        guard cardCount > 1 else {
            cardIndex = 0
            cardCount = 0
            return
        }
        let verified = reports.filter(\.isFullyVerified).count
        if verified == reports.count {
            controller?.lastNotice = L("offload_done_cards",
                                       localizedCount(verified, .card))
        }
        cardIndex = 0
        cardCount = 0
    }
}
