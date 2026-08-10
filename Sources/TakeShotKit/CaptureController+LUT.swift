import AVFoundation
import CaptureCore
import Foundation
import os.log

/// Applying a look: to the preview, to playback and to the recording.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. Getting look files
/// onto the machine, and off it into a cube, is `+LUTLibrary`.
extension CaptureController {
    /// Whether there is a look for the two switches to switch on.
    ///
    /// Four surfaces offer them — the badge popover, the View menu, the ⌃L key
    /// and the intensity row — and the popover was the one that did not ask,
    /// so it could store `previewEnabled = true` over no cube at all. Stated
    /// once here and asserted in the controller tests, the way
    /// `canChangeRecordingFormat` and `canDimMonitoring` are: "is it really
    /// gated" is a question about the rule, not about a rendered control.
    var canApplyLUT: Bool { settings.lut.fileName != nil }

    var lutPreviewOn: Bool {
        get { settings.lut.previewEnabled ?? false }
        set {
            settings.lut.previewEnabled = newValue
            // a per-clip "LUT off" left behind earlier must not eat the new
            // explicit enable — that read as "LUT does nothing in playback"
            if newValue, playbackLUTSuppressed { playbackLUTSuppressed = false }
            rebuildLUT()
        }
    }

    var lutRecordOn: Bool {
        get { settings.lut.recordEnabled ?? false }
        set {
            settings.lut.recordEnabled = newValue
            rebuildLUT()
        }
    }

    /// LUT intensity (0…1); default 1. Applied immediately (pipeline + tap mix
    /// coefficient only — no .cube re-read, no filter rebuild), persisted
    /// debounced: a settings write per tick re-rendered the window (slider lag).
    var lutIntensity: Double {
        get { live.lutIntensity }
        set {
            let clamped = min(1, max(0, newValue))
            live.lutIntensity = clamped
            pipeline.setLUTIntensity(clamped)
            playbackTap.setLUTIntensity(clamped)
            lutPersistTask?.cancel()
            lutPersistTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.settings.lut.intensity = self.live.lutIntensity
            }
        }
    }

    func selectLUT(fileName: String?) {
        settings.lut.fileName = fileName
        if fileName != nil, playbackLUTSuppressed { playbackLUTSuppressed = false }
        if fileName != nil, settings.lut.previewEnabled != true,
           settings.lut.recordEnabled != true {
            settings.lut.previewEnabled = true // picked a LUT — clearly want to see it
        }
        rebuildLUT()
    }
    /// Rebuild the filter and hand it to the pipeline and playback.
    func rebuildLUT() {
        currentCube = nil
        currentCDL = nil
        if let fileName = settings.lut.fileName {
            if let cache = cubeCache, cache.fileName == fileName {
                currentCube = cache.cube // checkbox flips must not re-read disk
                currentCDL = cache.cdl
            } else {
                loadLook(named: fileName)
            }
        }
        pipeline.setLUT(currentCube,
                        preview: settings.lut.previewEnabled ?? false,
                        record: settings.lut.recordEnabled ?? false,
                        intensity: live.lutIntensity)
        pipeline.setVideoLevels(settings.capture.videoLevels)
        applyPlaybackLUT()
    }
    /// LUT on playback — applied in the tap's own render (AVVideoComposition's
    /// pipeline shifted contrast even on untouched clips), accounting for an
    /// already-baked look: our file tagged com.takeshot.lut or a manual
    /// per-clip off — the LUT isn't applied twice.
    func applyPlaybackLUT() {
        guard settings.lut.previewEnabled ?? false, !playbackFileHasBakedLUT,
              !playbackLUTSuppressed,
              let cube = currentCube else {
            os_log("playback LUT OFF: preview=%d baked=%d suppressed=%d cube=%d",
                   log: CapturePipeline.levelsLog, type: .default,
                   (settings.lut.previewEnabled ?? false) ? 1 : 0,
                   playbackFileHasBakedLUT ? 1 : 0,
                   playbackLUTSuppressed ? 1 : 0,
                   currentCube != nil ? 1 : 0)
            playbackTap.setLUT(nil, intensity: 1)
            return
        }
        os_log("playback LUT ON: %{public}s intensity=%.2f",
               log: CapturePipeline.levelsLog, type: .default,
               settings.lut.fileName ?? "?", live.lutIntensity)
        // the cube crosses, and the filter is built on the tap's own queue
        playbackTap.setLUT({ cube.makeFilter() }, intensity: live.lutIntensity)
    }
    /// Check the loaded clip's baked-LUT tag (asynchronously).
    ///
    /// The file is opened for its metadata rather than the item's own asset
    /// being read, the same way `PlaybackFrameTap.detectLevels` asks the same
    /// file the neighbouring question — and here for a second reason as well:
    /// an `AVMetadataItem` is not `Sendable` in any macOS SDK, so the answer
    /// has to become a `Bool` inside the load's own nonisolated scope before
    /// it can come back to the main actor. Only one SDK enforces that (the
    /// macOS 26 overlay's `load` inherits the caller's isolation, the macOS 15
    /// one hops), which is why obeying it by construction is the point.
    func detectBakedLUT(for item: AVPlayerItem, at url: URL) {
        playbackFileHasBakedLUT = false
        Task { [weak self] in
            let baked = await Self.fileCarriesBakedLUT(at: url)
            await MainActor.run { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.playbackFileHasBakedLUT = baked
                self.applyPlaybackLUT()
            }
        }
    }

    /// Whether the file was written with a look already in the picture.
    /// Nonisolated: the metadata items are read and answered here, and only
    /// the answer leaves (see `detectBakedLUT`).
    nonisolated private static func fileCarriesBakedLUT(
        at url: URL) async -> Bool {
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        return metadata.contains { ($0.key as? String) == TakeWriter.lutKey }
    }
}
