import CaptureCore
import Combine
import Foundation

/// What the digital slate shows, and the sync flash/freeze it fires.
///
/// The card fields read STRAIGHT off the controller — the same settings the
/// pipeline is configured with and the same `pendingTakeName` the collision
/// warning and the web remote show — so the slate can never disagree with what
/// the writer is about to (or currently does) put on disk. Nothing here touches
/// the capture pipeline, the preview surfaces or the playout feeder: the slate
/// is a display window only.
///
/// Owned by the controller rather than by the window's view tree, so a hold in
/// progress survives the window being closed and reopened, and the tests reach
/// the same instance the window shows.
@MainActor
final class SlateModel: ObservableObject {
    private weak var controller: CaptureController?
    /// The card fields are computed off the controller, so its changes have to
    /// re-render the slate too — republished rather than observed twice by
    /// every view that reads through this model.
    private var forwarding: AnyCancellable?

    init(controller: CaptureController) {
        self.controller = controller
        forwarding = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - sync flash / freeze (the clap substitute)

    /// The one-frame-ish white flash is up.
    @Published private(set) var flashVisible = false
    /// The readout is holding the captured TC instead of the live clock.
    @Published private(set) var isFrozen = false
    /// The TC of the click moment; nil when nothing is held (or the click
    /// landed while there was no timecode — the hold then shows the fallback,
    /// never a stale number).
    private(set) var frozenTimecode: Timecode?

    /// How long the white flash stays up. About two frames at 25p: long enough
    /// to land on at least one frame of whatever camera is pointed at the
    /// slate, short enough to read as a clap, not a screen test.
    var flashHold: Duration = .milliseconds(100)
    /// How long the captured TC stays on screen — the editor's reading time.
    var freezeHold: Duration = .seconds(1)

    private var flashTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    /// Fire the sync flash: capture the TC of THIS moment, white-flash the
    /// face, and hold the captured TC on the readout while the live clock
    /// keeps running underneath. An editor syncs by finding the flash frame
    /// and reading the frozen number off the frames that follow it.
    ///
    /// Re-firing mid-hold re-captures — the newest click is the sync point.
    func fireSync() {
        flashTask?.cancel()
        releaseTask?.cancel()
        frozenTimecode = controller?.live.currentTimecode
        isFrozen = true
        flashVisible = true
        // the holds are copied out so a re-fire cannot retime a sleep already
        // in flight; the tasks themselves are cancelled instead
        let flashFor = flashHold
        let freezeFor = freezeHold
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: flashFor)
            guard let self, !Task.isCancelled else { return }
            self.flashVisible = false
        }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: freezeFor)
            guard let self, !Task.isCancelled else { return }
            self.isFrozen = false
            self.frozenTimecode = nil
        }
    }

    // MARK: - the timecode readout

    /// What the giant readout shows: the captured TC while the sync hold is
    /// on, otherwise the controller's live TC — the exact value the player
    /// badge reads, fallback included.
    var timecodeText: String {
        let shown = isFrozen ? frozenTimecode : controller?.live.currentTimecode
        return shown?.description ?? timecodeFallbackText
    }

    // MARK: - the card (straight off the controller)

    var projectName: String { controller?.settings.projectName ?? "" }
    var cameraLabel: String { controller?.settings.cameraLabel ?? "" }
    var roll: String { controller?.roll ?? "" }
    /// Clip number with the same padding the filename gets.
    var clipText: String { controller?.clipDisplay ?? "" }
    var isRecording: Bool { controller?.isRecording ?? false }

    /// The take name on the card. While recording this is the file actually
    /// being written (the clip number advances only on a successful finalize),
    /// otherwise the name the next take will get — one `pendingTakeName` for
    /// both, so the card cannot lie about what is being recorded.
    var takeName: String { controller?.pendingTakeName ?? "" }

    /// Live fps as the format badge shows it; nil with no signal.
    var fpsText: String? {
        (controller?.signalFormat).map { playerFPSText($0.frameRate) }
    }

    /// Today, unambiguous and locale-free — the same yyyy-MM-dd the naming
    /// engine writes for `{date}`.
    var dateText: String { Self.dateFormat.string(from: Date()) }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
