import AppKit
import Foundation
import Testing

@testable import TakeShotKit

/// What one key press over a running app means.
///
/// The rule lived inside `HotkeyManager.install`'s local `NSEvent` monitor,
/// which a test cannot drive — a monitor wants a real application event queue
/// and a synthesized event cannot be routed into one, so docs/coverage.md
/// listed it with the other monitor rows. `outcome` is that rule as a function
/// of the facts a press carries; what stays unreachable is the reading of them
/// off the event and the calls that apply the answer.
///
/// It is worth pinning on its own account. This decides whether the key under
/// the operator's finger reaches the app or the scene name they are halfway
/// through typing — the failure that took ⌃D away from every text field in the
/// app — and it decides the order two modal states are left in.
@MainActor
struct ModelHotkeyRoutingTests {
    private func manager() -> HotkeyManager {
        HotkeyManager(defaults: InMemoryDefaults())
    }

    /// keyCode 15 is the physical R key; ⌘R is the record default.
    private let recordKey: UInt16 = 15
    /// keyCode 3 is F, which `fullscreen` ships on with no modifier at all —
    /// the bare key that must not fire while the operator is typing.
    private let fullscreenKey: UInt16 = 3

    private func press(_ keyCode: UInt16,
                       modifiers: NSEvent.ModifierFlags = [],
                       key: String? = nil,
                       isTyping: Bool = false) -> HotkeyPress {
        HotkeyPress(keyCode: keyCode, modifiers: modifiers,
                    combo: key.map { KeyCombo(key: $0,
                                              modifiers: modifiers.rawValue,
                                              keyCode: keyCode) },
                    isTyping: isTyping)
    }

    private func outcome(_ manager: HotkeyManager, _ press: HotkeyPress,
                         playbackFullscreen: Bool = false,
                         liveFullscreen: Bool = false) -> HotkeyOutcome {
        manager.outcome(for: press, isPlaybackFullscreen: playbackFullscreen,
                        isLiveFullscreen: liveFullscreen)
    }

    // MARK: - the bindings

    @Test func aBoundChordRunsItsAction() {
        let manager = manager()
        #expect(outcome(manager, press(recordKey, modifiers: .command, key: "r"))
                == .perform(.toggleRecord))
        #expect(outcome(manager, press(fullscreenKey, key: "f"))
                == .perform(.fullscreen))
    }

    /// A press nothing answers to belongs to whatever has the keyboard — a
    /// menu equivalent, a button, a text field. Swallowing it would make the
    /// app eat keys it has no use for.
    @Test func anUnboundPressIsHandedOn() {
        let manager = manager()
        // ⌘R is the record key; ⌘⌥R is nobody's
        #expect(outcome(manager, press(recordKey,
                                       modifiers: [.command, .option], key: "r"))
                == .passThrough)
    }

    /// The rebound key answers and the old one stops. Going through `outcome`
    /// rather than through `bindings` is the point: the editor writes one place
    /// and the monitor reads another.
    @Test func rebindingMovesWhichPressRunsTheAction() {
        let manager = manager()
        let moved = KeyCombo(key: "j", modifiers: NSEvent.ModifierFlags.command.rawValue,
                             keyCode: 38)
        manager.assign(moved, to: .toggleRecord)

        #expect(outcome(manager, press(38, modifiers: .command, key: "j"))
                == .perform(.toggleRecord))
        #expect(outcome(manager, press(recordKey, modifiers: .command, key: "r"))
                == .passThrough)
    }

    // MARK: - typing

    /// While a text field owns the keyboard, only ⌘ combos reach the hotkeys.
    /// The bare and ⌃ families are the field's own — a ⌃ hotkey that stole them
    /// typed dim/mute into the operator's naming instead of editing it.
    @Test func typingKeepsTheFieldsOwnKeysAndYieldsCommandCombos() {
        let manager = manager()
        #expect(outcome(manager, press(fullscreenKey, key: "f", isTyping: true))
                == .passThrough, "a bare F went fullscreen mid-word")
        #expect(outcome(manager, press(recordKey, modifiers: .command, key: "r",
                                       isTyping: true))
                == .perform(.toggleRecord),
                "⌘R stopped recording the shot because a field had focus")
    }

    // MARK: - the two modal states, and their order

    /// Esc leaves the fullscreen the operator is in, and playback wins when
    /// both flags are somehow up — one key press leaves one surface.
    @Test func escapeLeavesTheFullscreenTheOperatorIsIn() {
        let manager = manager()
        let escape = press(HotkeyPress.escapeKeyCode, key: "escape")
        #expect(outcome(manager, escape, playbackFullscreen: true)
                == .leavePlaybackFullscreen)
        #expect(outcome(manager, escape, liveFullscreen: true)
                == .leaveLiveFullscreen)
        #expect(outcome(manager, escape, playbackFullscreen: true,
                        liveFullscreen: true) == .leavePlaybackFullscreen)
        // and with neither up it is nobody's key
        #expect(outcome(manager, escape) == .passThrough)
    }

    /// Esc cancels a recording — but only once there is no fullscreen surface
    /// left to leave. That order is deliberate (the fullscreen is the bigger
    /// state and this is the only way out of it) and its consequence is stated
    /// here rather than left to be found: a row armed while a fullscreen window
    /// is up stays armed until Esc is pressed a second time.
    @Test func escapeCancelsARecordingOnceThereIsNoFullscreenLeft() {
        let manager = manager()
        manager.recordingAction = .grabFrame
        let escape = press(HotkeyPress.escapeKeyCode, key: "escape")

        #expect(outcome(manager, escape, liveFullscreen: true)
                == .leaveLiveFullscreen)
        #expect(outcome(manager, escape) == .cancelRecording)
    }

    /// A chord pressed while a row is recording is bound to THAT row, whatever
    /// else it means: the recording state outranks every binding, or the key
    /// the operator is trying to assign would fire instead of being assigned.
    @Test func aChordPressedWhileRecordingIsBoundToTheArmedRow() {
        let manager = manager()
        manager.recordingAction = .grabFrame
        let combo = KeyCombo(key: "r", modifiers: NSEvent.ModifierFlags.command.rawValue,
                             keyCode: recordKey)

        #expect(outcome(manager, press(recordKey, modifiers: .command, key: "r"))
                == .bind(combo, to: .grabFrame),
                "⌘R fired the record button instead of landing on the row")
    }

    /// A press that is not a chord at all — a bare modifier, a key with no
    /// character — is swallowed and the row stays armed. Handing it on would
    /// let ⌘ alone reach a menu while the row blinks for a key.
    @Test func aPressThatIsNotAChordLeavesTheRowArmed() {
        let manager = manager()
        manager.recordingAction = .grabFrame
        #expect(outcome(manager, press(55, modifiers: .command)) // ⌘ alone
                == .keepRecording)
    }

    /// While recording, the typing guard does not apply: the operator is IN a
    /// text-shaped control by construction, and a bare key is exactly what they
    /// are trying to assign.
    @Test func recordingOutranksTheTypingGuard() {
        let manager = manager()
        manager.recordingAction = .grabFrame
        let bare = KeyCombo(key: "f", modifiers: 0, keyCode: fullscreenKey)
        #expect(outcome(manager, press(fullscreenKey, key: "f", isTyping: true))
                == .bind(bare, to: .grabFrame))
    }
}
