import CaptureCore
import CoreMedia

/// A backend delegate whose whole job is to hand the callback to its pipeline.
///
/// Both cameras do exactly that — `CaptureController` for the main one,
/// `CameraChannel` for each extra board in multicam — and both had written the
/// five forwarding methods out by hand. Five identical bodies twice is five
/// places for the two cameras to drift apart, which for the extra channels
/// means a bug nobody sees until a B-cam take comes back wrong.
///
/// The methods stay `nonisolated`: they arrive on the DeckLink thread and the
/// pipeline is the thing that owns the hop off it. Nothing here touches actor
/// state — `pipeline` is a `let` of a `Sendable` type.
protocol PipelineBackendDelegate: CaptureBackendDelegate {
    var pipeline: CapturePipeline { get }
}

extension PipelineBackendDelegate {
    nonisolated func backend(_ backend: CaptureBackend,
                             didDetectFormat format: CaptureFormat) {
        pipeline.handleFormat(format)
    }

    nonisolated func backend(_ backend: CaptureBackend,
                             didReceive frame: CapturedFrame) {
        pipeline.handleFrame(frame)
    }

    nonisolated func backend(_ backend: CaptureBackend,
                             didReceiveAudio sampleBuffer: CMSampleBuffer) {
        pipeline.handleAudio(sampleBuffer)
    }

    nonisolated func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        pipeline.handleSignal(present: signalPresent)
    }

    /// The default is to ignore it: only the main camera owns the device list.
    /// An extra channel is handed the board it is to run and does not go
    /// looking for another one.
    nonisolated func backendDeviceListChanged(_ backend: CaptureBackend) {}
}
