import CaptureCore
import Foundation

/// **Starting a dailies run, and the two controls that steer one.**
///
/// Split out of `DailiesQueueModel` when that type reached its length ceiling,
/// and a coherent piece rather than an arbitrary cut: everything here is the
/// handover — the values the sheet has collected becoming an engine call on a
/// background task, and the token that call can be stopped through. What the
/// run REPORTS is still next door, with the published state it writes into.
/// **What every pass of one run shares**: the burn-ins drawn over the picture,
/// where the files land, the look baked in, the squeeze taken out, the sound
/// matched to them, and whether finished items are skipped.
///
/// A value rather than nine parameters threaded twice — which is also what the
/// project's parameter-count limit says — and a real grouping rather than a
/// bag: what is NOT in here is exactly what a variant is allowed to change.
struct DailiesRunShared: Sendable {
    let burnins: DailiesBurnins
    let folder: URL
    let extras: [URL]
    let look: DailiesLook?
    let desqueeze: Double
    let sounds: [BroadcastWaveFacts]
    let skipFinished: Bool
}

extension DailiesQueueModel {
    func start() {
        guard canStart, let destination, let controller else { return }
        // **Every pass the run will make.** One without extras, which is the
        // run this app has always made; one more per extra variant.
        let passes = passes(settings: controller.settings)
        let total = passes.reduce(0) { $0 + $1.items.count }
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
        controller.dailiesStatus = L("dailies_status", 0, total)
        let extras = Array(destinations.dropFirst())
        let burnins = burnins
        // Captured on this side, like `burnins` and for the reason spelled out
        // below: the detached task is handed values, never this object.
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
        // The operator's own factor, read on this side with everything else
        // the task is handed. `desqueezeApplied` is 1 when the desqueeze is
        // switched off, so an operator who asked for the bake with no squeeze
        // dialled in gets the camera's raster — which is what they are looking
        // at.
        let squeeze = bakeDesqueeze ? controller.settings.assist.desqueezeApplied : 1
        // Every sound file the scan could read, handed over as values with
        // everything else: the matching per item happens inside the run,
        // because it is a fact about each take's timecode.
        let sounds = soundFindings.files
        // A VALUE, like everything else the task is handed: reading the
        // model's own property from inside the detached task is the capture
        // this file's header refuses.
        let skip = skipFinished
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
        let shared = DailiesRunShared(
            burnins: burnins, folder: destination, extras: extras, look: look,
            desqueeze: squeeze, sounds: sounds, skipFinished: skip)
        Task.detached(priority: .utility) {
            complete(await Self.runPasses(passes, total: total, shared: shared,
                                          control: token, publish: publish))
        }
    }

    /// **One pass's snapshot, renumbered onto the whole run.**
    ///
    /// Each engine call counts "item i of its own list" and the operator is
    /// watching ONE queue: without the offset the bar jumps back to the start
    /// of the line at every pass, and without the total it fills up and then
    /// starts again. Its own function because that is a statement about two
    /// numbers and the alternative is a closure nothing can check.
    /// `nonisolated` because the engine calls it from its own task: this is
    /// arithmetic on two integers and belongs to nobody's actor.
    nonisolated static func whole(_ snapshot: DailiesProgress, after done: Int,
                                  of total: Int) -> DailiesProgress {
        var moved = snapshot
        moved.itemIndex += done
        moved.itemCount = total
        return moved
    }

    /// **Each pass in turn, as one run.**
    ///
    /// Sequential and not parallel, deliberately: two transcodes of the same
    /// footage at once compete for the decoder, the disk and the pause gate
    /// that keeps a daily out of a rolling take's way — and the pass that
    /// finishes second finishes no sooner for it.
    ///
    /// Progress is renumbered onto the WHOLE run so the one bar the strip
    /// draws counts every pass: each engine call reports "item i of its own
    /// list", and the operator is watching one queue.
    ///
    /// Cancel stops the passes as well as the items, and the passes that never
    /// started report their items as cancelled — the engine's own rule, that a
    /// report's length always matches the queue's, applied one level up.
    private static func runPasses(
        _ passes: [DailiesPass], total: Int, shared: DailiesRunShared,
        control: DailiesControl,
        publish: @escaping @Sendable (DailiesProgress) -> Void)
        async -> DailiesReport {
        var all: [DailiesItemResult] = []
        var cancelled = false
        for (index, pass) in passes.enumerated() {
            guard !control.isCancelled else {
                all += passes[index...].flatMap { rest in
                    rest.items.map {
                        DailiesItemResult(source: $0.source, wasCancelled: true)
                    }
                }
                cancelled = true
                break
            }
            let done = all.count
            let result = await DailiesEngine.run(
                items: pass.items, burnins: shared.burnins, into: shared.folder,
                alsoInto: shared.extras, codec: pass.codec, look: shared.look,
                desqueeze: shared.desqueeze, resolution: pass.resolution,
                sounds: shared.sounds, skipFinished: shared.skipFinished,
                control: control,
                progress: { snapshot in
                    publish(whole(snapshot, after: done, of: total))
                })
            all += result.items
            cancelled = cancelled || result.wasCancelled
        }
        return DailiesReport(items: all, wasCancelled: cancelled)
    }

    /// Stop the whole queue. The frame in hand finishes and the partial
    /// output is deleted; items not reached are reported as cancelled.
    /// **Check what the destination holds against the journal it wrote.**
    ///
    /// Off the main actor, like every other pass that opens files: forty
    /// dailies over a network share is not an instant answer, and the sheet
    /// stays alive while it runs. The findings are published for the sheet and
    /// summarised as a toast, because the two readers want different things —
    /// "is the day all right" and "which file is not".
    func verifyDestination() {
        guard let folder = destination, !isVerifying, !isRunning else { return }
        isVerifying = true
        verifyFindings = []
        Task { [weak self] in
            let journal = DailiesProgressJournal.read(in: folder)
            let findings = await DailiesVerify.check(journal, in: folder)
            guard let self else { return }
            verifyFindings = findings
            isVerifying = false
            controller?.dailiesDidVerify(findings)
        }
    }

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
}
