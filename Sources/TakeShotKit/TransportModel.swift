import AVFoundation
import CaptureCore
import Combine
import Foundation

/// Playhead position only — isolated so the 10 Hz tick re-renders just the
/// TC readout and the slider, not the whole transport bar.
@MainActor
final class TransportPosition: ObservableObject {
    @Published var currentTime: Double = 0
}

/// Observing AVPlayer for the transport: time, speed, loop.
@MainActor
final class TransportModel: ObservableObject {
    let position = TransportPosition()
    var currentTime: Double { position.currentTime }
    @Published var duration: Double = 0
    /// Loop range (stuntmen watch one beat ten times in a row).
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    @Published var isPlaying = false
    @Published var desiredRate: Double = 1.0
    @Published var isLooping = true

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// Loop ranges filed by clip FILE NAME. A day is a few hundred clips holding
    /// two Doubles each, so the table is left to grow with the session; entries go
    /// when the clip does (`forgetClip`).
    ///
    /// The file name, not the URL, because that is the key the sidecar uses — the
    /// same key the ratings and the markers sidecars use — so the round trip
    /// through `takeshot-ranges.csv` needs no translation and cannot invent a URL
    /// for a clip that lives in a subfolder. Two clips of the same name in
    /// different subfolders would share a range; that is already true of their
    /// ratings and their markers.
    private var rangesByFile: [String: ClipRange] = [:]
    /// The clip `inPoint`/`outPoint` currently belong to. nil while the
    /// AVPlayer transport is not driving anything (a RAW clip or a still).
    private var loadedClip: URL?
    /// Told whenever a range actually changed, so the owner can rewrite the
    /// sidecar. Not called for a load that changed nothing, and deliberately not
    /// called by `forgetAllClips` — see there.
    var onRangesChanged: (() -> Void)?

    private static func key(_ url: URL) -> String { url.lastPathComponent }

    /// SF Symbols for the two range buttons.
    ///
    /// They used to be the other way round: the IN button carried the arrow
    /// that runs into a line on the RIGHT, which is how every NLE draws the end
    /// of a range, and the OUT button carried the left one. The bar belongs on
    /// the side the point marks — `|←` opens the range like an editor's `[`,
    /// `→|` closes it. Constants rather than literals in the two transport bars
    /// so the pair cannot drift apart again.
    static let inPointSymbol = "arrow.left.to.line.compact"
    static let outPointSymbol = "arrow.right.to.line.compact"

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        // The periodic observer below only fires while time advances, so when
        // playback stopped, `isPlaying` stayed true and the transport kept
        // showing a pause button over a stopped clip. The player's own status
        // reports the stop.
        statusObservation = player.observe(\.timeControlStatus,
                                           options: [.initial, .new]) { player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.position.currentTime = time.seconds
                let playing = player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
                if let item = player.currentItem, item.duration.isNumeric,
                   self.duration != item.duration.seconds {
                    self.duration = item.duration.seconds
                }
                // loop range: jump back at the out point while playing
                if playing, self.isLooping, let out = self.outPoint,
                   time.seconds >= out {
                    self.seek(to: self.inPoint ?? 0)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player,
                      (note.object as? AVPlayerItem) === player.currentItem,
                      self.isLooping else { return }
                let start = self.inPoint ?? 0
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                player.rate = Float(self.desiredRate)
            }
        }
    }

    func detach() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if let item = player.currentItem, item.duration.isNumeric,
               item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.rate = Float(desiredRate)
        }
    }

    /// Set/clear the in or out point at the playhead (click near an existing
    /// point clears it).
    func toggleRangePoint(out: Bool) {
        let before = currentRange
        let now = position.currentTime
        if out {
            if let existing = outPoint, abs(existing - now) < 0.1 {
                outPoint = nil
            } else {
                outPoint = now
                if let inP = inPoint, inP >= now { inPoint = nil }
            }
        } else {
            if let existing = inPoint, abs(existing - now) < 0.1 {
                inPoint = nil
            } else {
                inPoint = now
                if let outP = outPoint, outP <= now { outPoint = nil }
            }
        }
        // File it here rather than only when the clip is closed: this is the
        // moment the operator made the mark, and a quit before the next clip is
        // opened would otherwise lose it. Filing now also means closing the clip
        // finds nothing changed, so one mark is one write.
        guard currentRange != before, let loadedClip else { return }
        file(currentRange, for: loadedClip)
    }

    // MARK: - the range belongs to the clip

    /// In/out as they stand for the clip in the player.
    var currentRange: ClipRange {
        ClipRange(inPoint: inPoint, outPoint: outPoint)
    }

    /// The whole table, for the sidecar writer: what is on file, plus the range of
    /// the clip in the player, which is only filed when it is closed.
    var storedRanges: [String: ClipRange] {
        guard let loadedClip else { return rangesByFile }
        var all = rangesByFile
        all[Self.key(loadedClip)] = currentRange
        return all
    }

    /// Point the transport at `url`: file the outgoing clip's range and adopt
    /// this clip's (nothing on file = no range).
    ///
    /// There is ONE TransportModel for the whole app, so the range used to
    /// survive `replaceCurrentItem` untouched and land on the next clip at the
    /// same SECONDS offset — mark a beat 12 s into a 40 s take, load the next
    /// take, and it was already looping over 12 s of somebody else's action.
    ///
    /// `driving` is false for content this transport does not run: a RAW clip
    /// has its own engine and its own in/out, a still has no transport at all.
    /// The outgoing range is still filed, but nothing is adopted — otherwise
    /// this model's empty range would be written over the RAW engine's.
    func loadClip(_ url: URL?, driving: Bool = true) {
        if let loadedClip { file(currentRange, for: loadedClip) }
        guard let url, driving else {
            loadedClip = nil
            inPoint = nil
            outPoint = nil
            return
        }
        loadedClip = url
        let restored = rangesByFile[Self.key(url)] ?? .unset
        inPoint = restored.inPoint
        outPoint = restored.outPoint
    }

    /// The range on file for a clip this transport is not driving — how the RAW
    /// engine, rebuilt from scratch for every clip, gets its in/out back.
    func storedRange(for url: URL) -> ClipRange {
        rangesByFile[Self.key(url)] ?? .unset
    }

    func storeRange(_ range: ClipRange, for url: URL) {
        file(range, for: url)
    }

    /// Record a range against a clip, and say so only if it actually changed.
    /// Unchanged transitions have to stay silent: reviewing thirty clips without
    /// touching a mark must not rewrite the sidecar thirty times.
    private func file(_ range: ClipRange, for url: URL) {
        let key = Self.key(url)
        guard (rangesByFile[key] ?? .unset) != range else { return }
        rangesByFile[key] = range
        onRangesChanged?()
    }

    /// Ranges read back from the sidecar, for the clips a folder scan just found.
    ///
    /// Restricted to what the scan found so that a row for a clip that has been
    /// trashed cannot come back from a sidecar written before it went. Entries the
    /// session already knows are left alone — a scan runs every minute and on
    /// every folder event, and it must not undo a mark the operator just made.
    /// Silent by design: this is the read side, and notifying would write the file
    /// straight back.
    func restoreRanges(_ stored: [String: ClipRange],
                       forFilesNamed names: Set<String>) {
        for (name, range) in stored
        where names.contains(name) && rangesByFile[name] == nil {
            rangesByFile[name] = range
        }
        // the clip in the player was loaded before its range was on file
        if let loadedClip, currentRange.isEmpty {
            let restored = rangesByFile[Self.key(loadedClip)] ?? .unset
            inPoint = restored.inPoint
            outPoint = restored.outPoint
        }
    }

    /// A clip that was deleted takes its range with it — out of the table and out
    /// of the sidecar.
    func forgetClip(_ url: URL) {
        if rangesByFile.removeValue(forKey: Self.key(url)) != nil {
            onRangesChanged?()
        }
        guard loadedClip == url else { return }
        loadedClip = nil
        inPoint = nil
        outPoint = nil
    }

    /// A new record folder is a different set of clips.
    ///
    /// Deliberately silent, and this one matters: the destination has ALREADY
    /// changed by the time this runs (it is called from the settings observer), so
    /// notifying here would write an empty sidecar into the folder we are about to
    /// read one from — erasing the marks of whoever shot there this morning. The
    /// new folder's sidecar arrives through `restoreRanges` on the scan that
    /// follows.
    func forgetAllClips() {
        rangesByFile.removeAll()
        loadedClip = nil
        inPoint = nil
        outPoint = nil
    }

    func setRate(_ rate: Float) {
        desiredRate = Double(rate)
        if player?.rate != 0 {
            player?.rate = rate
        }
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
