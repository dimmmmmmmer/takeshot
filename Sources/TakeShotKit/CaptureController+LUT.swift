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
    var lutPreviewOn: Bool {
        get { settings.lutPreviewEnabled ?? false }
        set {
            settings.lutPreviewEnabled = newValue
            // a per-clip "LUT off" left behind earlier must not eat the new
            // explicit enable — that read as "LUT does nothing in playback"
            if newValue, playbackLUTSuppressed { playbackLUTSuppressed = false }
            rebuildLUT()
        }
    }

    var lutRecordOn: Bool {
        get { settings.lutRecordEnabled ?? false }
        set {
            settings.lutRecordEnabled = newValue
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
                self.settings.lutIntensity = self.live.lutIntensity
            }
        }
    }

    func selectLUT(fileName: String?) {
        settings.lutFileName = fileName
        if fileName != nil, playbackLUTSuppressed { playbackLUTSuppressed = false }
        if fileName != nil, settings.lutPreviewEnabled != true,
           settings.lutRecordEnabled != true {
            settings.lutPreviewEnabled = true // picked a LUT — clearly want to see it
        }
        rebuildLUT()
    }
    /// Rebuild the filter and hand it to the pipeline and playback.
    func rebuildLUT() {
        currentCube = nil
        currentCDL = nil
        if let fileName = settings.lutFileName {
            if let cache = cubeCache, cache.fileName == fileName {
                currentCube = cache.cube // checkbox flips must not re-read disk
                currentCDL = cache.cdl
            } else {
                loadLook(named: fileName)
            }
        }
        pipeline.setLUT(currentCube,
                        preview: settings.lutPreviewEnabled ?? false,
                        record: settings.lutRecordEnabled ?? false,
                        intensity: live.lutIntensity)
        pipeline.setVideoLevels(settings.videoLevels)
        applyPlaybackLUT()
    }
    /// LUT on playback — applied in the tap's own render (AVVideoComposition's
    /// pipeline shifted contrast even on untouched clips), accounting for an
    /// already-baked look: our file tagged com.takeshot.lut or a manual
    /// per-clip off — the LUT isn't applied twice.
    func applyPlaybackLUT() {
        guard settings.lutPreviewEnabled ?? false, !playbackFileHasBakedLUT,
              !playbackLUTSuppressed,
              let cube = currentCube else {
            os_log("playback LUT OFF: preview=%d baked=%d suppressed=%d cube=%d",
                   log: CapturePipeline.levelsLog, type: .default,
                   (settings.lutPreviewEnabled ?? false) ? 1 : 0,
                   playbackFileHasBakedLUT ? 1 : 0,
                   playbackLUTSuppressed ? 1 : 0,
                   currentCube != nil ? 1 : 0)
            playbackTap.setLUT(nil, intensity: 1)
            return
        }
        os_log("playback LUT ON: %{public}s intensity=%.2f",
               log: CapturePipeline.levelsLog, type: .default,
               settings.lutFileName ?? "?", live.lutIntensity)
        // the cube crosses, and the filter is built on the tap's own queue
        playbackTap.setLUT({ cube.makeFilter() }, intensity: live.lutIntensity)
    }
    /// Check the loaded clip's baked-LUT tag (asynchronously).
    func detectBakedLUT(for item: AVPlayerItem) {
        playbackFileHasBakedLUT = false
        Task { [weak self] in
            let metadata = (try? await item.asset.load(.metadata)) ?? []
            let baked = metadata.contains { ($0.key as? String) == TakeWriter.lutKey }
            await MainActor.run { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.playbackFileHasBakedLUT = baked
                self.applyPlaybackLUT()
            }
        }
    }
}
