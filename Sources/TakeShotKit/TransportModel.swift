import AVFoundation
import CaptureCore
import Combine
import Foundation

/// Observing AVPlayer for the transport: time, speed, loop.
///
/// The AVPlayer observation itself is `TransportModel+Player`; the table of
/// loop ranges filed by clip is `TransportModel+ClipRanges`. Members those
/// reach are module-internal rather than private for that reason.
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

    weak var player: AVPlayer?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var statusObservation: NSKeyValueObservation?

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
    var rangesByFile: [String: ClipRange] = [:]
    /// The clip `inPoint`/`outPoint` currently belong to. nil while the
    /// AVPlayer transport is not driving anything (a RAW clip or a still).
    var loadedClip: URL?
    /// Told whenever a range actually changed, so the owner can rewrite the
    /// sidecar. Not called for a load that changed nothing, and deliberately not
    /// called by `forgetAllClips` — see there.
    var onRangesChanged: (() -> Void)?

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

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            // The range decides FIRST. This used to seek to zero at the end of
            // the item and then ask, and with the loop off `rangeStart`
            // declined — so the zero stood and the whole clip replayed from the
            // head, ignoring the in point the operator had set. A clip with no
            // marks still gets the rewind, which is what it was for.
            if beginInsideRange() { return player.rate = Float(desiredRate) }
            if let item = player.currentItem, item.duration.isNumeric,
               item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.rate = Float(desiredRate)
        }
    }

    /// Where playback has to BEGIN for the loop range that is marked, given the
    /// playhead at `position`. nil when the playhead is already somewhere the
    /// range allows and nothing needs moving.
    ///
    /// This is the fix for a real bug, not a preference. The loop was enforced
    /// at the OUT point alone — the periodic observer seeks back when time
    /// passes it, and the end-of-item observer does the same at the tail — and
    /// nothing anywhere ever put the playhead INSIDE the range to start with. A
    /// fresh `AVPlayerItem` begins at zero, so the first pass over a clip with a
    /// range on it always played the whole lead-in and only then began looping,
    /// which is exactly what the operator saw.
    ///
    /// What reaching `time` means for a clip with an out point on it.
    ///
    /// Pure, and separate from the observer that acts on it, for the reason
    /// `rangeStart` is: the decision is the part worth pinning, and driving a
    /// real `AVPlayer` to its out point headlessly does not work — a test that
    /// tried it passed against the OLD behaviour too, because playback never
    /// started and "it stopped" was true before it began.
    ///
    /// The loop decides WHICH of the two things happens at the mark, never
    /// whether the mark is honoured: that gate is what made the marks read as
    /// ignored with the loop off (owner: "точки in out у нас не учитываются
    /// все еще при выключенном лупе").
    enum RangeAction: Equatable {
        /// Nothing to do — not playing, no out point, or not there yet.
        case carryOn
        /// Wrap to the in point and keep going.
        case wrap(to: Double)
        /// Stop, ON the mark rather than wherever the 10 Hz tick caught it.
        case stop(at: Double)
    }

    func rangeAction(atTime time: Double, playing: Bool) -> RangeAction {
        guard playing, let out = outPoint, time >= out else { return .carryOn }
        return isLooping ? .wrap(to: inPoint ?? 0) : .stop(at: out)
    }

    /// Pure and separate from the seek so the decision can be tested without a
    /// player attached.
    func rangeStart(forPlayheadAt position: Double) -> Double? {
        let start = inPoint ?? 0
        // Past the end of the range: the next play restarts it rather than
        // running on into whatever follows.
        //
        // NOT gated on looping, which it used to be — and that gate is why the
        // marks read as ignored with the loop off (owner: "точки in out у нас
        // не учитываются все еще при выключенном лупе"). An out point is where
        // the operator said this take ends; whether playback WRAPS there or
        // STOPS is what the loop button decides, and where the next press
        // starts from is not that question. The RAW engine's twin
        // (`startOfPlayback`) has never had the gate.
        if let outPoint, position >= outPoint { return start }
        // before it: the range is where the operator wants to be watching
        guard inPoint != nil, position < start - 0.001 else { return nil }
        return start
    }

    /// Put the playhead inside the range before playback starts.
    /// Returns whether it MOVED the playhead, so a caller can tell "the range
    /// put me somewhere" from "there was nothing to do".
    @discardableResult
    func beginInsideRange() -> Bool {
        guard let start = rangeStart(forPlayheadAt: position.currentTime)
        else { return false }
        seek(to: start)
        position.currentTime = start
        return true
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
