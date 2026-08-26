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

    private func clearMonitorTaps() {
        pipeline.setOnMonitorFrame(nil)
        for channel in extraChannels {
            channel.pipeline.setOnMonitorFrame(nil)
        }
    }
}
