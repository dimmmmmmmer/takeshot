import AppKit
import CaptureCore
import Combine
import Foundation

/// What the menu-bar item shows and what its menu does — with no `NSStatusItem`
/// in it.
///
/// Split from `MenuBarPresence` the way `SlateModel` was split from
/// `SlateView`: an `NSMenu` is built by AppKit at click time and can be neither
/// measured nor driven from a test, but everything worth asserting — which
/// title the record item is wearing, whether it is enabled, which controller
/// method each item lands on, how often the timecode is allowed to redraw — is
/// decided here and can be asserted headlessly.
///
/// Every action goes through the SAME controller method the on-screen button
/// calls. There is no second path to the recorder: the REC button, the web
/// remote and this menu are all `toggleManualRecord`, which is where the
/// pre-roll, the naming and the integrity alarms live.
@MainActor
final class MenuBarModel: ObservableObject {
    /// What an operator can tell from across the room without looking at the
    /// app at all.
    enum Presence: String {
        /// Nothing is being captured, or the wire is dead.
        case idle
        /// A live signal is running: armed, ready to roll.
        case ready
        /// A take is being written.
        case recording
    }

    /// The menu's actions. A closed set rather than a bag of closures, so a
    /// test can name the item it is pressing and the menu cannot grow a second
    /// path to anything.
    enum Command: String, CaseIterable {
        case toggleRecord
        case addMarker
        case toggleMute
        case openMain
        case quit
    }

    /// One row of the menu as AppKit will build it.
    struct Item: Equatable {
        /// nil — a separator, or a read-only row (the take name).
        var command: Command?
        var title: String
        var enabled: Bool
        /// Drawn with a checkmark. The mute item is a state, not a verb.
        var checked = false

        static let separator = Item(command: nil, title: "", enabled: false)
        var isSeparator: Bool { command == nil && title.isEmpty }
    }

    /// How often the menu-bar timecode is allowed to change, in seconds.
    ///
    /// The signal delivers a timecode at frame rate. A status item redrawn 25
    /// times a second re-lays out the system's own menu bar 25 times a second,
    /// for a readout no eye resolves at that rate. 2 Hz — unmistakably alive
    /// from across the room, and half the rate the web remote's status pump
    /// already runs the same number out at.
    static let titleInterval: TimeInterval = 0.5

    /// The clock the throttle reads. Injected so the rate can be proven without
    /// a test sleeping through it.
    var now: () -> Date = Date.init

    /// How the quit item ends the app. Injected for the same reason: a test
    /// that presses it must not take the test runner down with it.
    var quitAction: () -> Void = { NSApp.terminate(nil) }

    /// The state the button is drawing.
    @Published private(set) var presence: Presence = .idle
    /// The text beside the icon — the running take's timecode, and nothing at
    /// all when no take is running. A permanent string in the menu bar costs
    /// every other item's space for a number that means nothing when idle.
    @Published private(set) var statusTitle: String = ""

    /// How many times the throttle has let a timecode through. The value itself
    /// is usually the same string twice running (and is deduplicated before it
    /// reaches AppKit), so a counter is the only honest measure of the RATE.
    private(set) var titleEmissions = 0

    private weak var controller: CaptureController?
    private var lastTitleAt: Date?
    private var sinks: [AnyCancellable] = []
    /// A presence refresh is already queued for the next run-loop turn.
    private var refreshQueued = false

    init(controller: CaptureController) {
        self.controller = controller
        // The timecode ticks on LiveSignal, deliberately apart from the
        // controller so a per-frame value does not re-render the window (see
        // LiveSignal). This subscription runs at frame rate and is gated below.
        sinks.append(controller.live.$currentTimecode.sink { [weak self] _ in
            self?.timecodeTicked()
        })
        // …and the state that is NOT per-frame: capturing, signal, recording.
        // objectWillChange fires BEFORE the property is written, so the new
        // value is only readable on the next turn — hence the hop, coalesced so
        // a burst of controller writes costs one refresh.
        sinks.append(controller.objectWillChange.sink { [weak self] _ in
            self?.queueRefresh()
        })
        refresh()
    }

    // MARK: - what the button shows

    /// SF Symbol for the current state.
    var symbolName: String {
        switch presence {
        case .idle: return "video.slash"
        case .ready: return "video"
        case .recording: return "record.circle.fill"
        }
    }

    /// The recording indicator is drawn filled and RED rather than as a
    /// template image: the menu bar is otherwise monochrome, and "is it
    /// rolling" is the one question this item exists to answer at a glance.
    var isAlarmColored: Bool { presence == .recording }

    var tooltip: String {
        switch presence {
        case .idle: return L("menubar_status_idle")
        case .ready: return L("menubar_status_ready")
        case .recording: return L("menubar_status_recording")
        }
    }

    // MARK: - the menu

    /// The rows, built fresh each time the menu is about to open.
    ///
    /// Computed rather than published: the mute state, the take name and the
    /// marker item's enablement all change far more often than the menu is
    /// looked at, and none of them is worth a subscription that fires while the
    /// menu is closed.
    var items: [Item] {
        guard let controller else {
            return [Item(command: .quit, title: L("menubar_quit"), enabled: true)]
        }
        return [
            // A Stop item while nothing is rolling is a lie, and a live-looking
            // REC item with no device behind it is another one.
            Item(command: .toggleRecord,
                 title: controller.isRecording ? L("stop") : L("record"),
                 enabled: controller.isCapturing),
            Item(command: nil, title: L("menubar_take", takeName), enabled: false),
            .separator,
            // `canDropMarker` itself, not a copy of it: a marker needs either a
            // take being written or a clip in the SINGLE player — a grid of two
            // to four has no one file to put it in. This was that rule spelled
            // out a second time, which is how the METHOD came to be missing it
            // (see `addMarker`).
            Item(command: .addMarker, title: L("hotkey_marker"),
                 enabled: controller.canDropMarker),
            // Deliberately ungated, unlike the footer's speaker (which greys
            // with no capture and no clip): "kill the sound NOW" is the one
            // thing the status item exists for with the window closed, and the
            // ⌃A key is ungated too. Noted here because the two DO differ and
            // the difference is a choice, not an oversight.
            Item(command: .toggleMute, title: L("menubar_mute_monitor"),
                 enabled: true, checked: controller.live.muted),
            .separator,
            Item(command: .openMain, title: L("menubar_open_main"), enabled: true),
            .separator,
            Item(command: .quit, title: L("menubar_quit"), enabled: true),
        ]
    }

    /// The take being written, or the name the next one will get — the same
    /// `pendingTakeName` the collision warning, the slate and the phone all
    /// read, so the menu bar cannot disagree with what the writer is doing.
    private var takeName: String {
        let name = controller?.pendingTakeName ?? ""
        return name.isEmpty ? L("menubar_no_take") : name
    }

    /// Run a command, refusing one the menu would have shown greyed.
    ///
    /// AppKit will not send a disabled item, but it is not the only caller and
    /// the two must not be able to disagree — an item's enablement IS the
    /// guard, stated once.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        guard items.contains(where: { $0.command == command && $0.enabled }),
              let controller else { return false }
        switch command {
        case .toggleRecord: controller.toggleManualRecord()
        case .addMarker: controller.addMarker()
        case .toggleMute: controller.toggleMonitorMute()
        case .openMain: AppWindows.present(.main)
        // Through the normal terminate path, never a bespoke shutdown: that is
        // what runs `flushOnTerminate`, and quitting from the menu bar with no
        // window open is exactly the case where a take is still being written.
        case .quit: quitAction()
        }
        return true
    }

    // MARK: - state tracking

    /// A frame arrived. Called at the signal's rate; passes the gate at 2 Hz.
    func timecodeTicked() {
        guard presence == .recording else { return }
        let stamp = now()
        if let lastTitleAt,
           stamp.timeIntervalSince(lastTitleAt) < Self.titleInterval { return }
        lastTitleAt = stamp
        titleEmissions += 1
        let text = controller?.live.currentTimecode?.description ?? ""
        if statusTitle != text { statusTitle = text }
    }

    /// Re-read the state the button draws. Cheap and idempotent — nothing is
    /// published unless it actually moved.
    func refresh() {
        let current = computedPresence
        guard current != presence else { return }
        presence = current
        // Entering REC puts a timecode up without waiting out the gate; leaving
        // it takes the number away rather than freezing the last one on screen.
        lastTitleAt = nil
        if current == .recording {
            timecodeTicked()
        } else if !statusTitle.isEmpty {
            statusTitle = ""
        }
    }

    private var computedPresence: Presence {
        guard let controller else { return .idle }
        if controller.isRecording { return .recording }
        return controller.isCapturing && controller.signalPresent ? .ready : .idle
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }
}
