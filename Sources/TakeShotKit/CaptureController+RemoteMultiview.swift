import CaptureCore
import Foundation

/// The multiview stream, from the controller's side: the encoder that turns
/// preview frames into phone-sized JPEGs, and the taps that feed it.
///
/// The frames come off each pipeline's display path — the same latest-wins
/// hop the preview layers and the playout mirror ride, never the capture
/// queue — and go through `MultiviewEncoder`'s own queue for the scale and
/// the JPEG. Nothing here exists while nobody is watching: the server counts
/// subscribed clients and reports the edges, and this is where those edges
/// land.
extension CaptureController {
    /// Somebody started (or the last somebody stopped) watching. Hopped here
    /// from the server's queue; the taps and the encoder are MainActor state
    /// like the rest of the controller.
    func setRemoteMultiviewActive(_ active: Bool) {
        guard active else {
            clearRemoteMultiviewTaps()
            remoteMultiviewEncoder = nil
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
        refreshRemoteMultiviewTaps()
    }

    /// (Re)install the per-camera taps: the main pipeline is camera 0, the
    /// extra channels follow in order — the same order the status'
    /// `cameras` array and the page's tiles use. Called again whenever
    /// multicam reshapes the channel list.
    ///
    /// The count goes over too, because it is what sizes each tile: the page
    /// lays one camera out full screen and four in a 2-across grid, and the
    /// encoder has no other way to know which it is producing frames for. It
    /// is the SAME number the status' `cameras` array carries, from the same
    /// source, so the tile the phone draws and the frame it is handed cannot
    /// disagree about how big it should be.
    func refreshRemoteMultiviewTaps() {
        guard let encoder = remoteMultiviewEncoder else { return }
        encoder.setCameraCount(extraChannels.count + 1)
        pipeline.setOnMultiviewFrame { [weak encoder] buffer in
            encoder?.offer(buffer, camera: 0)
        }
        for (index, channel) in extraChannels.enumerated() {
            channel.pipeline.setOnMultiviewFrame { [weak encoder] buffer in
                encoder?.offer(buffer, camera: index + 1)
            }
        }
    }

    private func clearRemoteMultiviewTaps() {
        pipeline.setOnMultiviewFrame(nil)
        for channel in extraChannels {
            channel.pipeline.setOnMultiviewFrame(nil)
        }
    }
}
