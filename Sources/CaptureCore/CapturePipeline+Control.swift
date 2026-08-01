@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// What the MainActor asks the pipeline to do: levels, LUT and scope switches,
/// the settings hand-over, the manual REC button and the capture-stopped reset.
/// Every one of them hops onto `queue` — the pipeline's state is queue-confined
/// and none of it may be touched from the caller's thread.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    /// Input levels of the source signal: nil/"auto" — guess from the signal
    /// (RGB 4:4:4 → limited), "limited" (16-235) — expand once to full,
    /// "limited_excursions" — expand the whole legal swing (4-1019 in 10-bit)
    /// so the sub-blacks and super-whites `limited` clamps away survive, and
    /// "full" (0-255) — pass through (legacy "off" means the same). The strings
    /// are `InputLevels` raw values; this is the one place the legacy spelling
    /// is normalized, which is why `InputLevels.resolved` never sees it.
    public func setVideoLevels(_ mode: String?) {
        queue.async {
            switch mode {
            case "auto", nil: self.levelsMode = nil
            case "off": self.levelsMode = "full" // legacy value: pass through
            default: self.levelsMode = mode
            }
        }
    }

    /// Set the LUT (nil — off), apply modes, and intensity (0…1).
    public func setLUT(_ lut: CubeLUT?, preview: Bool, record: Bool,
                       intensity: Double = 1) {
        queue.async {
            self.lutFilter = lut?.makeFilter()
            self.lutName = lut?.name
            self.lutPreview = preview && lut != nil
            self.lutRecord = record && lut != nil
            self.lutIntensity = min(1, max(0, intensity))
            self.lutBufferPool.reset()
        }
    }

    /// Intensity only — no filter rebuild (for the slider: reacts to every tick
    /// without parsing the .cube and without disk operations).
    public func setLUTIntensity(_ intensity: Double) {
        queue.async { self.lutIntensity = min(1, max(0, intensity)) }
    }

    /// Toggle scope analysis (skipped entirely while off — zero cost).
    public func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.scopesEnabled = on
            // analyze the current frame right away — the scopes window should
            // open with data, not "waiting for signal"
            if on, let buffer = self.currentPreviewBuffer(),
               let scopeData = ScopeAnalyzer.analyze(buffer,
                                                    region: self.scopeRegion) {
                DispatchQueue.main.async { self.onScopeData?(scopeData) }
            }
        }
    }

    /// The part of the frame the scopes read: the crop the viewer displays
    /// while punched in, `.full` otherwise. The operator judges the exposure of
    /// what is on the glass, so the analysis follows the punch-in.
    ///
    /// The new region takes effect on the next frame rather than being analyzed
    /// here: a pan drag calls this ~60 times a second and this runs on the
    /// capture queue, which owns per-frame work and may not be handed a
    /// content-dependent 14 ms pass. The live signal is never more than a frame
    /// away anyway.
    public func setScopeRegion(_ region: ScopeRegion) {
        queue.async {
            guard region != self.scopeRegion else { return }
            self.scopeRegion = region
            self.lastScopeFrame = 0 // analyze the next frame, don't wait out the stride
        }
    }

    public func update(config: Config) {
        queue.async {
            let detectorChanged =
                config.settings.startDebounceFrames != self.config.settings.startDebounceFrames
                || config.settings.stopDebounceFrames != self.config.settings.stopDebounceFrames
                || config.settings.detectionMode != self.config.settings.detectionMode
            if config.settings.audioChannelMask
                != self.config.settings.audioChannelMask {
                // the packed-buffer format caches describe the OLD channel
                // count — reusing them mis-interleaves audio after a change
                self.trimFormatCache = nil
                self.monitorFormatCache = nil
            }
            self.config = config
            if detectorChanged {
                self.detector = RecDetector(config: RecDetectorConfig(
                    startDebounceFrames: config.settings.startDebounceFrames,
                    stopDebounceFrames: config.settings.stopDebounceFrames,
                    vancOnly: config.settings.detectionMode == .vanc))
            }
        }
    }

    /// Manual record start/stop (button).
    public func toggleManualRecord() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            } else {
                self.beginTake(timecode: self.lastTimecode)
            }
        }
    }

    /// Capture stopped: close the current take, reset state.
    public func captureStopped() {
        queue.async {
            if self.writer != nil {
                self.finishTake()
            }
            self.detector.reset()
            self.format = nil
            self.lastTimecode = nil
            self.latestLTC = nil // the old session's LTC must not name new takes
            self.ltcDecoder.reset()
            self.frameGrabHandler = nil
            self.preRollBuffer.removeAll()
            self.preRollAudio.removeAll()
            self.latestPreviewLock.lock()
            self.latestPreview = nil // don't compare against a frozen frame
            self.latestPreviewLock.unlock()
            self.rawVancStats.removeAll()
            self.vancStatsLastPublish = 0
            DispatchQueue.main.async {
                self.onFormatChanged?(nil)
                self.onTimecode?(nil)
                self.onVancStats?([])
                self.onAudioLevels?([])
            }
        }
    }
}
