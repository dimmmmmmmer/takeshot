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
    /// **Bake the viewing look into the proxies** (owner: "о в дейликах хочу
    /// еще возможность чтоб лут в них запекался"). Off unless the operator
    /// says otherwise — see `DailiesSettings.bakeLook` for why nil is not
    /// "whatever the old blob meant".
    @Published var bakeLook = false
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
    /// **Folders to render dailies FROM** (owner: "дейлики нужны из
    /// исходников… вероятно даже несколько источников, как в оффлоаде").
    /// Empty — the day's takes, which is what this sheet has always done.
    @Published private(set) var sources: [URL] = []
    /// What those folders hold, as of the last scan (`DailiesSourceScan`).
    @Published private(set) var findings = DailiesSourceScan.Findings()
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

    private var control: DailiesControl?
    private var scanTask: Task<Void, Never>?
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
            .CombineLatest3($sources, $findings, $queuedTakes)
            .map { Self.contents(sources: $0, findings: $1, takes: $2).firstURL }
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

    /// Seed the sheet from the operator's saved convention and clear the
    /// previous run's result — a stale "done" card over a fresh batch reads
    /// as that batch being finished.
    func prepare(takes: [Take], settings: CaptureSettings, defaultFolder: URL) {
        if !isRunning {
            progress = nil
            report = nil
            isCancelling = false
            queuedTakes = takes
        }
        timecodePosition = settings.dailies.timecodePositionEffective
        clipNamePosition = settings.dailies.clipNamePositionEffective
        projectPosition = settings.dailies.projectPositionEffective
        customPosition = settings.dailies.customPositionEffective
        datePosition = settings.dailies.datePositionEffective
        burnTimecode = settings.dailies.burnTimecode ?? true
        burnClipName = settings.dailies.burnClipName ?? true
        burnProject = settings.dailies.burnProject ?? true
        burnDate = settings.dailies.burnDate ?? false
        burnCustom = settings.dailies.burnCustomEffective
        customText = settings.dailies.customText ?? ""
        codec = settings.dailies.codecEffective
        bakeLook = settings.dailies.bakeLook == true
        namePrefix = settings.dailies.namePrefixEffective
        nameSuffix = settings.dailies.nameSuffixEffective
        ink = settings.dailies.inkEffective
        customInk = settings.dailies.customInkEffective
        // The folders a run rendered from come back with it: the same card
        // tree returns every shooting day. Only the ones still THERE — a card
        // that has been unplugged is not a source, and a list full of dead
        // paths is a list nobody trusts.
        sources = settings.dailies.sourceURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        rescan()
        self.defaultFolder = defaultFolder
        destinations = [settings.dailies.destinationPath
            .map { URL(fileURLWithPath: $0) } ?? defaultFolder]
            + settings.dailies.extraDestinationURLs
    }

    /// How many files this Start will produce.
    var itemCount: Int {
        sources.isEmpty ? queuedTakes.count : findings.files.count
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
    private func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        CaptureController.comparablePath(lhs)
            == CaptureController.comparablePath(rhs)
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

    var burnins: DailiesBurnins {
        DailiesBurnins(
            timecode: burnTimecode, clipName: burnClipName,
            project: burnProject, date: burnDate,
            // The switch decides, and the words are left alone: the engine's
            // rule is still "empty text, no strip", so switching the line off
            // is expressed by handing it nothing while the operator's sentence
            // stays in the field and in settings.
            customText: burnCustom
                ? customText.trimmingCharacters(in: .whitespaces) : "",
            timecodePosition: timecodePosition,
            clipNamePosition: clipNamePosition,
            projectPosition: projectPosition,
            customPosition: customPosition,
            datePosition: datePosition,
            ink: ink, customInk: customInk)
    }

    // MARK: - the run

    func start() {
        guard canStart, let destination, let controller else { return }
        let items = plannedItems(settings: controller.settings)
        let token = DailiesControl()
        // Recording protection from the first frame: a queue started while a
        // take is rolling opens already paused and waits its turn.
        token.setPaused(controller.isRecording)
        control = token
        isRunning = true
        isCancelling = false
        progress = nil
        report = nil
        controller.rememberDailiesChoices(from: self)
        controller.dailiesStatus = L("dailies_status", 0, items.count)
        let extras = Array(destinations.dropFirst())
        let burnins = burnins
        // Captured on this side, like `burnins` and for the reason spelled out
        // below: the detached task is handed values, never this object.
        let codec = codec
        // **Built on this side, like everything else the task is handed.** The
        // cube and its name live on the controller and the task is a detached
        // one: a look read from over there would be this object crossing into
        // the task's region, which is the toolchain difference the paragraph
        // below is about. Nil unless the operator asked AND there is a look to
        // bake — `canApplyLUT` is the rule the row is disabled on.
        let look: DailiesLook? = bakeLook
            ? controller.currentCube.map {
                DailiesLook(cube: $0,
                            name: controller.settings.lut.fileName ?? $0.name,
                            intensity: controller.live.lutIntensity)
            }
            : nil
        // Both ways back are built HERE, on the main actor, and the task is
        // handed nothing else of ours. A reference the task captured belongs
        // to the task's own region, and passing THAT to a closure that will
        // run on the main actor is what the older Swift compiler rejects
        // ("sending 'self' risks causing data races" — this is a toolchain
        // difference, not an SDK one; Dispatch is declared identically in
        // both). Captured on this side the reference is the main actor's from
        // the start, which is also the truer description of what it is.
        //
        // FIFO onto the main queue, like the offload's progress: a Task per
        // snapshot could land out of order, and the report has to arrive
        // behind the last snapshot rather than beside it.
        let publish: @Sendable (DailiesProgress) -> Void = { [weak self] snapshot in
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
        let complete: @Sendable (DailiesReport) -> Void = { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
        // Utility priority, off the main actor: the encode must never compete
        // with the capture path for the machine (the pause gate guards the
        // disk and encoder; this guards the CPU).
        Task.detached(priority: .utility) {
            let result = await DailiesEngine.run(
                items: items, burnins: burnins, into: destination,
                alsoInto: extras, codec: codec, look: look, control: token,
                progress: publish)
            complete(result)
        }
    }

    /// Stop the whole queue. The frame in hand finishes and the partial
    /// output is deleted; items not reached are reported as cancelled.
    func cancel() {
        guard isRunning else { return }
        control?.cancel()
        isCancelling = true
        controller?.dailiesStatus = L("dailies_cancelling")
    }

    /// Skip the item in flight; the next one starts. Index-keyed so a skip
    /// pressed as an item finishes cannot spill onto the next.
    func skipCurrentItem() {
        guard isRunning, let index = progress?.itemIndex else { return }
        control?.skip(item: index)
    }

    /// The REC gate, called from the controller's recording state: the queue
    /// holds while a take rolls and resumes when it ends.
    func recordingStateChanged(_ recording: Bool) {
        control?.setPaused(recording)
    }

    // MARK: - what the run reports back

    private func apply(_ snapshot: DailiesProgress) {
        guard isRunning else { return }
        progress = snapshot
        guard !isCancelling else { return }
        controller?.dailiesStatus = snapshot.isPaused
            ? L("dailies_paused_rec")
            : L("dailies_status", min(snapshot.itemIndex + 1,
                                      snapshot.itemCount),
                snapshot.itemCount)
    }

    private func finish(_ result: DailiesReport) {
        isRunning = false
        isCancelling = false
        progress = nil
        report = result
        control = nil
        controller?.dailiesDidFinish(result)
    }
}
