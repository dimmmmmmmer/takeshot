import AppKit
import Combine
import CaptureCore
import Foundation

/// State of the dailies sheet, and the queue it drives.
///
/// Owned by the controller rather than by the view, like `OffloadSheetModel`
/// and for the same reasons: the run outlives any render of the sheet, the
/// takes-panel status strip reads from it, and the REC state has to reach a
/// running queue whether the sheet is on screen or not. File panels stay out
/// of it so everything engine-facing is reachable from a test.
@MainActor
final class DailiesQueueModel: ObservableObject {
    // The burn-in switches, seeded from settings and written back on Start.
    /// Where each burned-in line sits. Published like the toggles beside them,
    /// so the preview under the rows follows a picker as it is changed.
    @Published var timecodePosition: DailiesBurninPosition = .topCenter
    @Published var clipNamePosition: DailiesBurninPosition = .bottomLeft
    @Published var projectPosition: DailiesBurninPosition = .bottomRight
    @Published var customPosition: DailiesBurninPosition = .topLeft
    @Published var datePosition: DailiesBurninPosition = .bottomRight
    @Published var burnTimecode = true
    @Published var burnClipName = true
    @Published var burnProject = true
    @Published var burnDate = false
    /// The custom line has a switch of its own now (owner: "не хватает как
    /// будто галочки у кастом тайтла"). It used to be the TEXT: non-empty was
    /// on, so the only way to turn the line off was to delete what you had
    /// written — and `rememberDailiesChoices` then stored nil, which threw it
    /// away for good. Off keeps the words.
    @Published var burnCustom = false
    @Published var customText = ""
    /// What the dailies are written in, and therefore also which container
    /// and extension they get (`CaptureCodec.dailiesChoices`).
    @Published var codec: CaptureCodec = .h264
    /// **How far the daily is scaled down** (owner: "давай сделаем выбор
    /// насколько снижать резолюшн"). 1080p is what every daily was before the
    /// choice existed, and stays the default.
    @Published var resolution: DailiesResolution = .hd
    /// **More versions of the same day** (owner: "и да, очередь из нескольких
    /// вариантов дейликов будет супер"), beyond the one the row above
    /// describes.
    ///
    /// Empty by default, which is the whole of the compatibility story: a run
    /// with no extras is byte for byte the run this app has always made. Each
    /// extra is another PASS over the same takes, which is why the list is
    /// capped (`DailiesVariant.limit`) — the cost is decodes, not rows.
    @Published var extraVariants: [DailiesVariant] = []
    /// **Every review copy at the same level.** Off by default — a level this
    /// app decided cannot be taken back out of a proxy.
    @Published var normalizeAudio = false
    /// **Bake the viewing look into the proxies** (owner: "о в дейликах хочу
    /// еще возможность чтоб лут в них запекался"). Off unless the operator
    /// says otherwise — see `DailiesSettings.bakeLook` for why nil is not
    /// "whatever the old blob meant".
    @Published var bakeLook = false
    /// **Bake the anamorphic desqueeze into the proxies.** Off unless the
    /// operator says so — see `DailiesSettings.bakeDesqueeze`.
    @Published var bakeDesqueeze = false
    /// The output name's two ends, around the take's own name.
    @Published var namePrefix = ""
    @Published var nameSuffix = "_DAILY"
    /// How solid the burn-ins are — the technical lines and the custom line
    /// each have their own plate and lettering (`DailiesInk`).
    @Published var ink: DailiesInk = .standard
    @Published var customInk: DailiesInk = .standard
    /// **A real frame to lay the preview's strips over**, or nil for the flat
    /// grey (owner: "хотелось бы чтобы картинкой встал как пример какой-то
    /// один стилл из любого исходника… вместо серого фона").
    ///
    /// On the MODEL and not read from the environment by the preview, and
    /// that is load-bearing: the sheet's `content` is a computed property the
    /// render tests ask for directly, and an `@EnvironmentObject` reached that
    /// way traps — which took a whole battery down once. The controller fills
    /// this in when the sheet opens (`dailiesPreviewStill`).
    @Published var previewStill: CGImage?
    /// **Where the dailies land** — one or more (owner: "и так же несколько
    /// источников дестинейшна, ну мало ли что").
    ///
    /// The FIRST is where the encode is written; the rest are given a copy of
    /// the finished file. Copied and not re-encoded: a second encode would
    /// double the cost of the whole batch to produce a byte-identical file,
    /// and the machine is shared with a capture path that must not be made to
    /// wait.
    @Published var destinations: [URL] = []

    /// The destination the encode is written into — the head of the list, and
    /// what every reader that only cares about "where does this land" asks.
    var destination: URL? {
        get { destinations.first }
        set {
            guard let newValue else { destinations = []; return }
            if destinations.isEmpty {
                destinations = [newValue]
            } else {
                destinations[0] = newValue
            }
        }
    }
    /// The folder beside the footage — what `destination` means when the
    /// operator has not pointed it anywhere. Held so the sheet can offer the way
    /// BACK to it and so a run that lands there is not recorded as a choice:
    /// the record folder is re-pointed between shows, and a saved absolute path
    /// would aim the next show's dailies at the last one's disk.
    @Published private(set) var defaultFolder: URL?
    /// What Start will queue, in take order. Seeded by the controller from
    /// the panel selection (or the whole day) when the sheet opens.
    ///
    /// Ignored while `sources` is non-empty: a run is either the app's own
    /// takes or the folders the operator pointed at, never both — two sets of
    /// files under one Start is a batch nobody can predict the contents of.
    @Published var queuedTakes: [Take] = []
    /// **Render only the circled takes** (owner: "давай еще сделаем галку
    /// где-нибудь типа рендерить только удачные тейки").
    ///
    /// Off by default, because a day's dailies are the day: the filter is for
    /// the second pass an assistant sends to the director. It reaches the
    /// queue through `takesToRender`, which is the one place the list is
    /// narrowed, so the count on the button, the preview's frame and what
    /// Start actually renders cannot come to disagree.
    @Published var goodTakesOnly = false
    /// **Leave alone what this folder already holds** (owner: "не рендерить
    /// уже отрендеренное — точно да").
    ///
    /// ON by default, and that is the safe default rather than the polite one:
    /// without it a second run over the same day writes a `_2` beside every
    /// daily — the no-silent-overwrite rule doing exactly what it should, to a
    /// folder nobody wanted doubled. What "already holds" means is the
    /// folder's own journal plus the disk (`DailiesJournal`), so a changed
    /// arrangement, a changed source or a missing file all render again.
    @Published var skipFinished = true
    /// **What the last check of the destination found** (owner: "ну и чтобы
    /// какая-то у нас проверка типа как после копий была что все файлы точно
    /// отрендерены как надо") — empty until one is run.
    /// Written by `verifyDestination` in `+Run` and nowhere else — the
    /// `private(set)` this would otherwise carry cannot reach across the file
    /// the check moved into, and the sheet only ever reads them.
    @Published var verifyFindings: [DailiesVerify.Finding] = []
    /// A check is going. It opens every daily in the folder, which is fast and
    /// is not instant on forty of them over a network.
    @Published var isVerifying = false
    /// **Folders to render dailies FROM** (owner: "дейлики нужны из
    /// исходников… вероятно даже несколько источников, как в оффлоаде").
    /// Empty — the day's takes, which is what this sheet has always done.
    @Published private(set) var sources: [URL] = []
    /// What those folders hold, as of the last scan (`DailiesSourceScan`).
    @Published private(set) var findings = DailiesSourceScan.Findings()
    /// **Folders of the sound recordist's files** (owner: "было бы классно
    /// иметь возможность выбрать папку со звуком"). Empty — the daily carries
    /// the camera's own sound and nothing else.
    @Published private(set) var soundFolders: [URL] = []
    /// What those hold, and what could not be used: a file with no `bext`
    /// timecode can be matched to nothing, and an operator who pointed at the
    /// wrong folder has to find that out before the run, not after it.
    @Published private(set) var soundFindings = DailiesSoundScan.Findings()
    /// A scan is running: the folder may be a shuttle drive with a thousand
    /// clips on it, so the walk is off the main actor and the sheet says so.
    @Published private(set) var isScanning = false
    /// Live state of the run; nil when nothing is running.
    @Published var progress: DailiesProgress?
    /// The last finished run — the sheet's result panel.
    @Published var report: DailiesReport?
    @Published var isRunning = false
    /// Stop has been pressed: the frame in hand finishes, then the run ends.
    @Published var isCancelling = false

    /// Internal rather than private since the run moved into `+Run`: the
    /// token is the run, and Stop and Skip are the two things that reach it.
    var control: DailiesControl?
    private var scanTask: Task<Void, Never>?
    private var soundScanTask: Task<Void, Never>?
    /// Internal rather than private since the queue-contents extension moved
    /// into its own file: `previewItem` asks it for the settings an item is
    /// composed against.
    weak var controller: CaptureController?
    /// The subscription that writes the arrangement down — see `attach`.
    private var changes: AnyCancellable?
    /// Fires the preview's frame when the queue's first item changes — see
    /// `attach(to:)`.
    private var firstItemChanges: AnyCancellable?

    /// Wired once, in startup, rather than when the sheet opens — a queue
    /// reports through the controller (status line, toast) and must not run
    /// silently if it is ever started another way. Same contract as the
    /// offload model's `attach`.
    func attach(to controller: CaptureController) {
        self.controller = controller
        // **Every change is remembered, not just the ones that were RUN.**
        //
        // The arrangement used to be written on Start alone, on the argument
        // that "a half-set sheet that was never run is not a convention". It
        // is: an operator sets the folders and the switches for the day, shuts
        // the sheet, and comes back to find none of it (owner: "дейлики не
        // сохраняют настройки! ни папку которую я выбирал ни галки, ниче").
        //
        // `objectWillChange` fires BEFORE the value lands, which is exactly
        // why the write is debounced rather than immediate — by the time the
        // slot fires, the new value is the one being read. It also collapses
        // a slider drag into one settings write, which is what the whole
        // `DebouncedSettings` exists for.
        changes = objectWillChange.sink { [weak self] _ in
            self?.rememberSoon()
        }
        // **The preview's frame follows what the run is made of.** Subscribed
        // to the two published values `queueContents` is a function of rather
        // than to `objectWillChange`, which fires for a slider drag as well —
        // and the answer to this one is a decode. `removeDuplicates` on the
        // first item is what makes a rescan that finds the same card cost
        // nothing.
        firstItemChanges = Publishers
            .CombineLatest4($sources, $findings, $queuedTakes, $goodTakesOnly)
            .map {
                Self.contents(sources: $0, findings: $1, takes: $2,
                              goodOnly: $3).firstURL
            }
            .removeDuplicates()
            // **A turn later, and that is the second half of the willSet
            // trap.** The values above are the ones being SET, so the compare
            // is right — but the work below reads the model and the panel's
            // thumbnail cache, and at `willSet` time those still hold what the
            // change is replacing. Without this hop the refresh ran against the
            // previous card and left the preview on the frame it was already
            // showing.
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in
                controller?.refreshDailiesPreviewStill()
            }
    }

    /// Write the sheet's arrangement down, shortly.
    private func rememberSoon() {
        guard let controller, !isRunning else { return }
        controller.debounced.schedule(
            .dailies, after: Self.rememberDelay) { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.rememberDailiesChoices(from: self)
        }
    }

    /// Long enough to collapse a slider drag, short enough that closing the
    /// sheet and quitting cannot outrun it — the quit guard flushes every slot
    /// anyway (`DebouncedSettings.flushAll`).
    static let rememberDelay: Duration = .milliseconds(400)

    /// How many files this Start will produce.
    var itemCount: Int {
        sources.isEmpty ? takesToRender.count : findings.files.count
    }

    var canStart: Bool {
        !isRunning && !isScanning && itemCount > 0 && destination != nil
    }

    // MARK: - the folders

    /// **Folders are compared by PATH, never by `URL` equality.**
    ///
    /// `URL(fileURLWithPath:)` gives a directory that exists a trailing
    /// slash and one that does not none, so a folder restored from settings
    /// and the same folder picked in a panel are two unequal URLs for one
    /// place — and Remove would have missed the row the operator clicked.
    /// `comparablePath` is the same rule the offload's destination list and
    /// the dailies default-folder check already use.
    /// Internal since the sound folders moved into `+Queue`: two lists of
    /// folders, one rule for "the same one".
    func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        CaptureController.comparablePath(lhs)
            == CaptureController.comparablePath(rhs)
    }

    /// The folder beside the footage, which is where a daily goes unless the
    /// operator said otherwise. Written here for the reason `restoreFolders`
    /// is: this file is the only writer of it.
    func adoptDefaultFolder(_ folder: URL) {
        defaultFolder = folder
    }

    /// **The folder lists a relaunch brings back**, and only the folders that
    /// are still THERE: a card that has been unplugged is not a source, and a
    /// list full of dead paths is a list nobody trusts.
    ///
    /// Here rather than in `+Prepare` because these two are `private(set)` and
    /// this file is the only writer — the point of the annotation is that a
    /// folder list changes through `addSource`/`addSoundFolder` and their
    /// rescans, never by assignment from somewhere else.
    func restoreFolders(sources restored: [URL], sound: [URL]) {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        sources = restored.filter { exists($0.path) }
        rescan()
        soundFolders = sound.filter { exists($0.path) }
        rescanSound()
    }

    func addSoundFolder(_ url: URL) {
        guard !soundFolders.contains(where: { isSame($0, url) }) else { return }
        soundFolders.append(url)
        rescanSound()
    }

    func removeSoundFolder(_ url: URL) {
        soundFolders.removeAll { isSame($0, url) }
        rescanSound()
    }

    /// Re-point a sound folder in PLACE, the way a source folder is re-pointed.
    ///
    /// The recordist's card comes back under a different mount point every
    /// day, and the row's own Choose button is how it is followed — it was
    /// drawn with nothing behind it, which is a button that looks like the
    /// sources' and does nothing at all.
    func replaceSoundFolder(_ old: URL, with url: URL) {
        guard let index = soundFolders.firstIndex(where: { isSame($0, old) })
        else { return }
        soundFolders[index] = url
        rescanSound()
    }

    /// Read the sound folders again, off the main actor.
    ///
    /// Its own walk rather than a branch of `rescan`: it reads a different
    /// kind of file with a different reader, and a day's sound is tens of
    /// gigabytes the picture scan has no reason to wait for.
    func rescanSound() {
        soundScanTask?.cancel()
        guard !soundFolders.isEmpty else {
            soundFindings = DailiesSoundScan.Findings()
            return
        }
        let folders = soundFolders
        soundScanTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                DailiesSoundScan.scan(folders)
            }.value
            guard !Task.isCancelled else { return }
            self?.soundFindings = found
        }
    }

    func addSource(_ url: URL) {
        guard !sources.contains(where: { isSame($0, url) }) else { return }
        sources.append(url)
        rescan()
    }

    func removeSource(_ url: URL) {
        sources.removeAll { isSame($0, url) }
        rescan()
    }

    func replaceSource(_ old: URL, with url: URL) {
        guard let index = sources.firstIndex(where: { isSame($0, old) })
        else { return }
        sources[index] = url
        rescan()
    }

    func addDestination(_ url: URL) {
        guard !destinations.contains(where: { isSame($0, url) }) else { return }
        destinations.append(url)
    }

    func removeDestination(_ url: URL) {
        // Never the head: that is where the encode lands, and a run with
        // nowhere to write is not a run.
        guard let index = destinations.firstIndex(where: { isSame($0, url) }),
              index > 0 else { return }
        destinations.remove(at: index)
    }

    func replaceDestination(_ old: URL, with url: URL) {
        guard let index = destinations.firstIndex(where: { isSame($0, old) })
        else { return }
        destinations[index] = url
    }

    /// Walk the folders again, off the main actor.
    ///
    /// A shuttle drive with a thousand clips on it is a walk that takes
    /// seconds, and the sheet has to stay answerable while it runs — the same
    /// reason `DiskProbe` exists.
    func rescan() {
        scanTask?.cancel()
        guard !sources.isEmpty else {
            findings = DailiesSourceScan.Findings()
            isScanning = false
            return
        }
        let folders = sources
        // **Cleared before the walk, not after it.** `findings` was replaced
        // only when it landed, so between pointing at a new card and the walk
        // finishing, every reading taken from it — the batch count in the
        // header, the file count on the files tab, the frame the preview lays
        // its strips over — was the PREVIOUS card's, beside a folder list
        // already showing the new one (owner: "при обновлении папки сорсов
        // превью не обновляется и не подгоняется вся новая инфа под новое
        // превью"). Empty is the honest answer while `isScanning` is true, and
        // it is the answer every one of those readings already knows how to
        // draw.
        findings = DailiesSourceScan.Findings()
        isScanning = true
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                DailiesSourceScan.scan(folders)
            }.value
            guard !Task.isCancelled else { return }
            self?.findings = found
            self?.isScanning = false
        }
    }

    /// Whether the destination is still the folder beside the footage.
    ///
    /// The one question that decides what gets STORED: a destination equal to
    /// the default is not an override, so nothing is written and the folder
    /// follows the record folder wherever the next show points it. Compared
    /// lexically through `comparablePath` for the reason stated there — neither
    /// folder need exist yet.
    var isDestinationDefault: Bool {
        guard let destination else { return true }
        guard let defaultFolder else { return false }
        return CaptureController.comparablePath(destination)
            == CaptureController.comparablePath(defaultFolder)
    }

    // MARK: - what the run reports back

    func apply(_ snapshot: DailiesProgress) {
        guard isRunning else { return }
        progress = snapshot
        guard !isCancelling else { return }
        controller?.dailiesStatus = snapshot.isPaused
            ? L("dailies_paused_rec")
            : L("dailies_status", min(snapshot.itemIndex + 1,
                                      snapshot.itemCount),
                snapshot.itemCount)
    }

    func finish(_ result: DailiesReport) {
        isRunning = false
        isCancelling = false
        progress = nil
        report = result
        control = nil
        controller?.dailiesDidFinish(result)
    }
}
