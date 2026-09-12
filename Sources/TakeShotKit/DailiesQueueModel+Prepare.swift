import CaptureCore
import Foundation

/// **What opening the dailies sheet restores.**
///
/// Split out of `DailiesQueueModel` when that type reached its length ceiling,
/// and a piece rather than an arbitrary cut: everything here answers one
/// question — what the operator left set up last time. The burn-ins, the
/// codec, the two bakes, the folders of footage and of sound, and the shelves
/// each daily is copied to.
extension DailiesQueueModel {
    /// Seed the sheet from the operator's saved convention and clear the
    /// previous run's result — a stale "done" card over a fresh batch reads
    /// as that batch being finished.
    func prepare(takes: [Take], settings: CaptureSettings, defaultFolder: URL) {
        if !isRunning {
            progress = nil
            report = nil
            isCancelling = false
            queuedTakes = takes
        }
        timecodePosition = settings.dailies.timecodePositionEffective
        clipNamePosition = settings.dailies.clipNamePositionEffective
        projectPosition = settings.dailies.projectPositionEffective
        customPosition = settings.dailies.customPositionEffective
        datePosition = settings.dailies.datePositionEffective
        burnTimecode = settings.dailies.burnTimecode ?? true
        burnClipName = settings.dailies.burnClipName ?? true
        burnProject = settings.dailies.burnProject ?? true
        burnDate = settings.dailies.burnDate ?? false
        burnCustom = settings.dailies.burnCustomEffective
        customText = settings.dailies.customText ?? ""
        codec = settings.dailies.codecEffective
        resolution = settings.dailies.resolutionEffective
        extraVariants = settings.dailies.variantsEffective
        bakeLook = settings.dailies.bakeLook == true
        bakeDesqueeze = settings.dailies.bakeDesqueeze == true
        goodTakesOnly = settings.dailies.goodTakesOnly == true
        skipFinished = settings.dailies.skipFinishedEffective
        namePrefix = settings.dailies.namePrefixEffective
        nameSuffix = settings.dailies.nameSuffixEffective
        ink = settings.dailies.inkEffective
        customInk = settings.dailies.customInkEffective
        // The folders a run rendered from come back with it: the same card
        // tree returns every shooting day. Only the ones still THERE — a card
        // that has been unplugged is not a source, and a list full of dead
        // paths is a list nobody trusts.
        restoreFolders(sources: settings.dailies.sourceURLs,
                       sound: settings.dailies.soundURLs)
        adoptDefaultFolder(defaultFolder)
        destinations = [settings.dailies.destinationPath
            .map { URL(fileURLWithPath: $0) } ?? defaultFolder]
            + settings.dailies.extraDestinationURLs
    }
}
