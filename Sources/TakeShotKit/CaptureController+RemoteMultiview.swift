import CaptureCore
import Foundation

/// The crew monitoring stream, from the controller's side: the composed grid
/// picture a browser watches as video, and the per-camera taps that feed it.
///
/// **One slot, and it was shared.** There were two consumers here until the
/// JPEG `/cameras` page was retired, and both wanted `LivePicture.clean` from
/// every live board — that is what makes a monitoring surface rather than an
/// assist one — so they rode the SAME slot
/// (`CapturePipeline.setOnMonitorFrame`) and each named the picture it wanted
/// out of the frame that arrived. Two slots would have been two readings of
/// what clean means, which is the drift `LivePicture` exists to prevent, and
/// the rule outlives the second consumer.
///
/// The frames come off each pipeline's display path — the same latest-wins hop
/// the preview layers and the playout mirror ride, never the capture queue —
/// and each consumer's own queue does the work. Nothing here exists while
/// nobody is watching: the server counts subscribed `/cameras` clients and the
/// encoder pool knows whether the grid picture is being watched, and the tap
/// goes back to nil when neither is true.
extension CaptureController {
    /// (Re)install the per-camera monitor taps: the main pipeline is camera 0,
    /// the extra channels follow in order — the same order the status'
    /// `cameras` array and the page's tiles use. Called again whenever multicam
    /// reshapes the channel list, and whenever either consumer appears or goes.
    ///
    /// The count is what sizes what the composer produces — it picks a layout
    /// off it. It is the SAME number the status' `cameras` array carries, from
    /// the same source, so a cell in the video grid and the count a page reads
    /// cannot disagree.
    ///
    /// There was a second consumer here until the JPEG `/cameras` page was
    /// removed: an encoder that emitted one JPEG per board for a page to lay
    /// out. The live page carries the composed grid as video and chooses its
    /// own picture, so the second transport had nothing left that the first did
    /// not do better.
    func refreshMonitorTaps() {
        let composer = mirrors.gridComposer
        guard composer != nil else {
            clearMonitorTaps()
            return
        }
        let cameras = extraChannels.count + 1
        composer?.setCameraCount(cameras)
        // The names and lamps for the count just set, so a grid that opens
        // mid-shift is labelled on its first composed frame rather than on
        // its first timecode tick.
        pushGridIdentities()
        // The rate is captured per WIRING and not read per frame, exactly as
        // `wireDisplayMirrors` does it and for the same reason: the handler runs
        // on the display queue and the frame rate is MainActor state. The
        // composer wants it so the grid's encoder is built for the rate the
        // master camera is actually running at.
        let rate = signalFormat?.frameRate ?? 0
        pipeline.setOnMonitorFrame { [weak composer] frame in
            composer?.offer(frame[.grid], camera: 0, framesPerSecond: rate)
        }
        for (index, channel) in extraChannels.enumerated() {
            let camera = index + 1
            let channelRate = channel.signalFormat?.frameRate ?? 0
            channel.pipeline.setOnMonitorFrame { [weak composer] frame in
                composer?.offer(frame[.grid], camera: camera,
                                framesPerSecond: channelRate)
            }
        }
    }

    /// **Every live tile says which board it is, whether it is writing, whether
    /// it is feeding at all, and what its own timecode reads.**
    ///
    /// `.camera`, from the same expressions the operator's own grid already
    /// reads — `settings.naming.cameraLabel` for the
    /// main board and `CameraChannel.camLabel` for each extra — so a name
    /// burned into the picture cannot disagree with either surface. The lamp is
    /// each pipeline's OWN `isRecording` and never the app's: in multicam the
    /// boards record apart, and a B-cam whose writer died must not glow red on
    /// A-cam's word. That rule is already written out twice, at
    /// `RemoteStatus.CameraState` and at `MulticamGrid`; this is the third
    /// surface to answer it and it asks the same question rather than a
    /// similar one.
    ///
    /// **`signalPresent` is per board for the identical reason**, and it is the
    /// only reading of it anywhere: `CaptureController.signalPresent` for the
    /// main board and `CameraChannel.signalPresent` for each extra, both of
    /// them written by `CapturePipeline.onSignal` and by nothing else. A B-cam
    /// whose cable is out must say so on its own tile while A-cam carries on,
    /// which a session-wide flag could not express.
    ///
    /// **What the per-tick restatement buys here is the whole wiring.** A
    /// dropout has no event of its own on this path — it is a value that
    /// changes on the pipeline's own thread — and this method already says
    /// everything on every tick, so a B-cam losing signal reaches the picture
    /// within one frame of the main camera with nothing subscribed to it.
    /// **The main board is the case that does not work that way**, and it is a
    /// property of the pacing rather than of this push: camera 0 losing signal
    /// stops the composer's clock (`MultiviewComposer.Pacing.clock`), so no
    /// pass runs and the far end holds the last grid it was sent. Its own
    /// legend is written into an identity nothing will draw until frames come
    /// back. Closing that is a change to what RUNS a compose, not to what a
    /// badge says.
    ///
    /// **Restated wholesale rather than diffed**, and that is the design. The
    /// label, the lamp and the clock change at three different rates and from
    /// three different places, so working out which of them moved would be
    /// three subscriptions and three chances to miss one. Instead this says all
    /// of it, the badge cache is keyed on what is drawn, and an unchanged
    /// statement costs a dictionary lookup. Called from the frame path's own
    /// timecode tick, so the picture is at most one frame behind the truth.
    ///
    /// Costs nothing while nobody is watching the grid: with no composer this
    /// returns on the first line, which is the same discipline the taps
    /// themselves follow.
    func pushGridIdentities() {
        guard let composer = mirrors.gridComposer else { return }
        composer.setIdentity(
            .camera(label: settings.naming.cameraLabel, recording: isRecording,
                    signalPresent: signalPresent),
            camera: 0)
        composer.setClock(live.currentTimecode?.description, camera: 0)
        for (index, channel) in extraChannels.enumerated() {
            composer.setIdentity(
                .camera(label: channel.camLabel, recording: channel.isRecording,
                        signalPresent: channel.signalPresent),
                camera: index + 1)
            composer.setClock(channel.currentTimecode?.description,
                              camera: index + 1)
        }
    }

    private func clearMonitorTaps() {
        pipeline.setOnMonitorFrame(nil)
        for channel in extraChannels {
            channel.pipeline.setOnMonitorFrame(nil)
        }
    }
}
