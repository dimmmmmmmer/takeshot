import CaptureCore
import Foundation

/// The crew monitoring streams, from the controller's side: the JPEG tiles the
/// `/cameras` page shows, the composed grid picture a browser can watch as
/// video, and the taps that feed both.
///
/// **Two consumers of one tap, and that is the point.** Both want
/// `LivePicture.clean` from every live board — that is what makes them
/// monitoring surfaces rather than assist ones — so they ride the SAME slot
/// (`CapturePipeline.setOnMonitorFrame`) and each names the picture it wants
/// out of the frame that arrives. Two slots would be two readings of what clean
/// means, which is exactly the drift `LivePicture` exists to prevent.
///
/// The frames come off each pipeline's display path — the same latest-wins hop
/// the preview layers and the playout mirror ride, never the capture queue —
/// and each consumer's own queue does the work. Nothing here exists while
/// nobody is watching: the server counts subscribed `/cameras` clients and the
/// encoder pool knows whether the grid picture is being watched, and the tap
/// goes back to nil when neither is true.
extension CaptureController {
    /// Somebody started (or the last somebody stopped) watching the `/cameras`
    /// page. Hopped here from the server's queue; the taps and the encoder are
    /// MainActor state like the rest of the controller.
    func setRemoteMultiviewActive(_ active: Bool) {
        guard active else {
            remoteMultiviewEncoder = nil
            refreshMonitorTaps()
            return
        }
        if remoteMultiviewEncoder == nil {
            // The sink runs on the encoder's queue and must not touch the
            // MainActor — a busy main thread would pace the stream. The
            // server is captured weakly instead: `broadcastFrame` hops to its
            // own queue, and a server being replaced is not kept alive by the
            // stream it used to feed (stopRemoteServer drops the encoder
            // anyway; the weak reference is what makes a race with it inert).
            let server = remoteServer
            remoteMultiviewEncoder = MultiviewEncoder { [weak server] camera, jpeg in
                server?.broadcastFrame(camera: camera, jpeg: jpeg)
            }
        }
        refreshMonitorTaps()
    }

    /// (Re)install the per-camera monitor taps: the main pipeline is camera 0,
    /// the extra channels follow in order — the same order the status'
    /// `cameras` array and the page's tiles use. Called again whenever multicam
    /// reshapes the channel list, and whenever either consumer appears or goes.
    ///
    /// The count goes to both consumers, because it is what sizes what they
    /// produce: the JPEG encoder picks a tile edge off it (a single camera is a
    /// whole phone, four are a quarter each) and the composer picks a layout.
    /// It is the SAME number the status' `cameras` array carries, from the same
    /// source, so a tile the phone draws and a cell in the video grid cannot
    /// disagree about how many there are.
    func refreshMonitorTaps() {
        let jpeg = remoteMultiviewEncoder
        let composer = mirrors.gridComposer
        guard jpeg != nil || composer != nil else {
            clearMonitorTaps()
            return
        }
        let cameras = extraChannels.count + 1
        jpeg?.setCameraCount(cameras)
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
        pipeline.setOnMonitorFrame { [weak jpeg, weak composer] frame in
            jpeg?.offer(frame[.clean], camera: 0)
            composer?.offer(frame[.grid], camera: 0, framesPerSecond: rate)
        }
        for (index, channel) in extraChannels.enumerated() {
            let camera = index + 1
            let channelRate = channel.signalFormat?.frameRate ?? 0
            channel.pipeline.setOnMonitorFrame { [weak jpeg, weak composer] frame in
                jpeg?.offer(frame[.clean], camera: camera)
                composer?.offer(frame[.grid], camera: camera,
                                framesPerSecond: channelRate)
            }
        }
    }

    /// **Every live tile says which board it is, whether it is writing, and
    /// what its own timecode reads.**
    ///
    /// `.camera`, from the same two expressions the operator's own grid and the
    /// `/cameras` page already read — `settings.naming.cameraLabel` for the
    /// main board and `CameraChannel.camLabel` for each extra — so a name
    /// burned into the picture cannot disagree with either surface. The lamp is
    /// each pipeline's OWN `isRecording` and never the app's: in multicam the
    /// boards record apart, and a B-cam whose writer died must not glow red on
    /// A-cam's word. That rule is already written out twice, at
    /// `RemoteStatus.CameraState` and at `MulticamGrid`; this is the third
    /// surface to answer it and it asks the same question rather than a
    /// similar one.
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
            .camera(label: settings.naming.cameraLabel, recording: isRecording),
            camera: 0)
        composer.setClock(live.currentTimecode?.description, camera: 0)
        for (index, channel) in extraChannels.enumerated() {
            composer.setIdentity(
                .camera(label: channel.camLabel, recording: channel.isRecording),
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
