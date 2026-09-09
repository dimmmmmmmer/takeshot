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
    /// The output name's two ends, around the take's own name.
    @Published var namePrefix = ""
    @Published var nameSuffix = "_DAILY"
    /// How solid the burn-ins are — the technical lines and the custom line
    /// each have their own plate and lettering (`DailiesInk`).
    @Published var ink: DailiesInk = .standard
    @Published var customInk: DailiesInk = .standard
    /// Where the dailies land. Defaults to a Dailies folder beside the takes.
    @Published var destination: URL?
    /// The folder beside the footage — what `destination` means when the
    /// operator has not pointed it anywhere. Held so the sheet can offer the way
    /// BACK to it and so a run that lands there is not recorded as a choice:
    /// the record folder is re-pointed between shows, and a saved absolute path
    /// would aim the next show's dailies at the last one's disk.
    @Published private(set) var defaultFolder: URL?
    /// What Start will queue, in take order. Seeded by the controller from
    /// the panel selection (or the whole day) when the sheet opens.
    @Published var queuedTakes: [Take] = []
    /// Live state of the run; nil when nothing is running.
    @Published var progress: DailiesProgress?
    /// The last finished run — the sheet's result panel.
    @Published var report: DailiesReport?
    @Published var isRunning = false
    /// Stop has been pressed: the frame in hand finishes, then the run ends.
    @Published var isCancelling = false

    private var control: DailiesControl?
    private weak var controller: CaptureController?

    /// Wired once, in startup, rather than when the sheet opens — a queue
    /// reports through the controller (status line, toast) and must not run
    /// silently if it is ever started another way. Same contract as the
    /// offload model's `attach`.
    func attach(to controller: CaptureController) {
        self.controller = controller
    }

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
        namePrefix = settings.dailies.namePrefixEffective
        nameSuffix = settings.dailies.nameSuffixEffective
        ink = settings.dailies.inkEffective
        customInk = settings.dailies.customInkEffective
        self.defaultFolder = defaultFolder
        destination = settings.dailies.destinationPath
            .map { URL(fileURLWithPath: $0) } ?? defaultFolder
    }

    var canStart: Bool {
        !isRunning && !queuedTakes.isEmpty && destination != nil
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

    /// The name one take's daily will be written under, without the extension
    /// — what the sheet shows as a live example.
    func outputName(for takeName: String) -> String {
        Self.outputName(take: takeName, prefix: namePrefix, suffix: nameSuffix)
    }

    /// **The whole naming rule, in one place.**
    ///
    /// `NameField.prefix.normalized` is what the operator's typing already
    /// goes through in the fields, but the RESULT is what reaches
    /// `appendingPathComponent`, and nothing on that path sanitized it before:
    /// a prefix of "../" or a name that came out empty had a filesystem answer
    /// and no app answer. So the joined name is normalized again here.
    ///
    /// Two things `normalized` alone does not do, both found by the test that
    /// tried them:
    ///
    /// - **Leading dots are dropped.** `normalized` removes the separators, so
    ///   "../../" cannot climb out of the dailies folder — but it leaves the
    ///   dots, and a name beginning with one is a file macOS hides. A daily
    ///   the operator cannot see in Finder is worse than a daily with an odd
    ///   name.
    /// - **An empty result falls back to the take's own name.** An empty path
    ///   component handed to `appendingPathComponent` names the dailies
    ///   FOLDER, and a daily with no name is not a daily.
    static func outputName(take: String, prefix: String,
                           suffix: String) -> String {
        let joined = NameField.prefix.normalized(prefix + take + suffix)
        let visible = String(joined.drop(while: { $0 == "." }))
        return visible.isEmpty ? take : visible
    }

    // MARK: - the run

    func start() {
        guard canStart, let destination, let controller else { return }
        let items = queuedTakes.map {
            Self.item(for: $0, settings: controller.settings,
                      prefix: namePrefix, suffix: nameSuffix)
        }
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
        let burnins = burnins
        // Captured on this side, like `burnins` and for the reason spelled out
        // below: the detached task is handed values, never this object.
        let codec = codec
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
                codec: codec, control: token, progress: publish)
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

    // MARK: - what the engine is told about one take

    /// A take as a queue item: the file, the `<name>_DAILY` output, and the
    /// burn-in facts composed from the settings that own them.
    static func item(for take: Take, settings: CaptureSettings,
                     prefix: String = "", suffix: String = "_DAILY")
        -> DailiesItem {
        // **The project alone.** It used to be "PROJECT · A001" — the camera
        // and the roll appended — and the roll is already in the file name
        // this run writes (owner: "из места где проект убери подпись ролла. он
        // же в названии файла дописывается и так"). A burn-in that repeats
        // what the name says spends a strip on nothing.
        let projectLine = settings.naming.projectName
        // ISO date, POSIX locale: a burn-in is read by post in another
        // country, and "03/04" means two different days to two of them.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return DailiesItem(
            source: take.url,
            outputName: outputName(take: take.displayName, prefix: prefix,
                                   suffix: suffix),
            clipName: take.displayName,
            projectLine: projectLine,
            dateText: stamp.string(from: take.recordedAt),
            startTimecode: take.startTimecode)
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
