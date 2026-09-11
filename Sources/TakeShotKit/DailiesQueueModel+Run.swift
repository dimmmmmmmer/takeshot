import CaptureCore
import Foundation

/// **Starting a dailies run, and the two controls that steer one.**
///
/// Split out of `DailiesQueueModel` when that type reached its length ceiling,
/// and a coherent piece rather than an arbitrary cut: everything here is the
/// handover — the values the sheet has collected becoming an engine call on a
/// background task, and the token that call can be stopped through. What the
/// run REPORTS is still next door, with the published state it writes into.
extension DailiesQueueModel {
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
        Task.detached(priority: .utility) {
            let result = await DailiesEngine.run(
                items: items, burnins: burnins, into: destination,
                alsoInto: extras, codec: codec, look: look,
                desqueeze: squeeze, sounds: sounds,
                skipFinished: skip, control: token,
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
}
