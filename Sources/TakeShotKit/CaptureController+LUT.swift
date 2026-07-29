import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Look-up tables: importing, selecting, and applying them to the preview,
/// to playback and to the recording.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    struct LUTInfo: Identifiable, Equatable {
        var id: String { fileName }
        var fileName: String
        var name: String
    }

    enum DuplicateLUTChoice { case replace, keepBoth, skip }

    nonisolated static var lutsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("TakeShot/LUTs", isDirectory: true)
    }

    /// DaVinci Resolve's LUT directory — imported LUTs are mirrored into a
    /// TakeShot subfolder there, so the same look is at hand in Resolve.
    nonisolated static var resolveLUTDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent(
                "Application Support/Blackmagic Design/DaVinci Resolve/LUT/TakeShot",
                isDirectory: true)
    }

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

    func reloadLUTList() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        availableLUTs = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { LUTInfo(fileName: $0.lastPathComponent,
                           name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name < $1.name }
    }
    /// Import .cube: copied into the app folder and selected right away.
    func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lastName: String?
        for url in panel.urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                // duplicate name: let the user decide instead of silently replacing
                switch Self.askDuplicateLUT(name: url.lastPathComponent) {
                case .replace:
                    try? FileManager.default.removeItem(at: dest)
                case .keepBoth:
                    dest = CapturePipeline.uniqueURL(for: dest)
                case .skip:
                    continue
                }
            }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                lastName = dest.lastPathComponent
                mirrorLUTToResolve(dest)
            } catch {
                lastError = "LUT import failed: \(error.localizedDescription)"
            }
        }
        reloadLUTList()
        if let lastName {
            selectLUT(fileName: lastName)
        }
    }
    /// Open the imported-LUTs folder in Finder.
    func openLUTsInFinder() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
    /// Delete all imported .cube files and clear the selected LUT.
    func clearLUTs() {
        let dir = Self.lutsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "cube" {
            try? FileManager.default.removeItem(at: file)
        }
        selectLUT(fileName: nil)
        reloadLUTList()
    }
    /// Modal: what to do with an already-imported LUT of the same name.
    private static func askDuplicateLUT(name: String) -> DuplicateLUTChoice {
        let alert = NSAlert()
        alert.messageText = L("lut_duplicate_title", name)
        alert.informativeText = L("lut_duplicate_text")
        alert.addButton(withTitle: L("lut_replace"))
        alert.addButton(withTitle: L("lut_keep_both"))
        alert.addButton(withTitle: L("lut_skip"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .skip
        }
    }
    /// Mirror an imported LUT into DaVinci Resolve's LUT/TakeShot folder.
    private func mirrorLUTToResolve(_ url: URL) {
        let dir = Self.resolveLUTDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
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
        if let fileName = settings.lutFileName {
            if let cache = cubeCache, cache.fileName == fileName {
                currentCube = cache.cube // checkbox flips must not re-read disk
            } else {
                let url = Self.lutsDirectory.appendingPathComponent(fileName)
                do {
                    let cube = try CubeLUT.load(url: url)
                    currentCube = cube
                    cubeCache = (fileName, cube)
                } catch {
                    lastError = "LUT: \(error.localizedDescription)"
                    settings.lutFileName = nil
                }
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
              let cube = currentCube, let filter = cube.makeFilter() else {
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
        playbackTap.setLUT(filter, intensity: live.lutIntensity)
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
