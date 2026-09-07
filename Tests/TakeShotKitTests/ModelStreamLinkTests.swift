import Foundation
import Testing

@testable import TakeShotKit

/// One reading of "is the link up" across three outputs that report in their
/// own vocabularies.
///
/// The distinction this exists to keep is the whole feature: an indicator must
/// show the LINK, not the switch. SRT already made it — a listener with a bound
/// port and nobody dialled in is `.starting`, which is what the bridge measures
/// rather than a convention. NDI did not: it wrote "sending" one line after the
/// source was created, so its lamp lit because a checkbox was ticked.
struct ModelStreamLinkTests {
    @Test func aSwitchedOnLinkNobodyIsTakingIsNotUp() {
        #expect(StreamLink(SRTOutputState.starting) == .waiting)
        #expect(StreamLink(NDIOutputState.announced) == .waiting,
                "an announced NDI source claimed somebody was watching")
        #expect(StreamLink(PlayoutState.opened) == .waiting,
                "an opened board claimed a picture was on the monitor")
        #expect(StreamLink(SRTOutputState.sending) == .up)
        #expect(StreamLink(NDIOutputState.sending) == .up)
        #expect(StreamLink(PlayoutState.feeding) == .up)
    }

    @Test func offIsTheOnlyStateWithNothingToSay() {
        #expect(!StreamLink(SRTOutputState.off).isEngaged)
        #expect(!StreamLink(NDIOutputState.off).isEngaged)
        #expect(!StreamLink(PlayoutState.off).isEngaged)
        for engaged in [StreamLink.waiting, .up, .trouble("x")] {
            #expect(engaged.isEngaged)
        }
    }

    /// Trouble outranks everything — it is the one an operator has to see
    /// mid-shoot — and one live link is a picture leaving the machine even
    /// while the other waits.
    @Test func theTwoLinksCombineByWhatMattersMost() {
        #expect(StreamLink.combined([.up, .trouble("gone")]) == .trouble("gone"))
        #expect(StreamLink.combined([.waiting, .up]) == .up)
        #expect(StreamLink.combined([.off, .waiting]) == .waiting)
        #expect(StreamLink.combined([.off, .off]) == .off)
        #expect(StreamLink.combined([]) == .off)
    }

    /// Both readings are exhaustive switches with no `default:`, so a case
    /// added to either transport fails to compile here rather than arriving as
    /// a green light. Asserted by naming every case that exists today: this
    /// test stops compiling when one is added, which is the point.
    @Test func everyTransportStateHasAReading() {
        // Built here rather than taken from a bridge: on a machine where the
        // SDKs ARE installed both answer nil, and this test is about the
        // reading rather than about what this machine happens to have.
        let bridge = BridgeUnavailable(code: "srt_not_built",
                                       english: "no libsrt in this build")
        let srt: [SRTOutputState] = [
            .off, .starting, .sending, .reconnecting("why"), .failed("why"),
            .unavailable(bridge),
        ]
        let ndi: [NDIOutputState] = [
            .off, .announced, .sending, .failed("why"),
            .unavailable(bridge),
        ]
        let playout: [PlayoutState] = [.off, .opened, .feeding, .stalled("why")]
        #expect(srt.map(StreamLink.init).count == srt.count)
        #expect(ndi.map(StreamLink.init).count == ndi.count)
        #expect(playout.map(StreamLink.init).count == playout.count)
        // Trouble carries what to say about it, in every case that has words.
        #expect(StreamLink(SRTOutputState.reconnecting("cable")) == .trouble("cable"))
        #expect(StreamLink(NDIOutputState.failed("no route")) == .trouble("no route"))
        #expect(StreamLink(PlayoutState.stalled("board taken"))
                == .trouble("board taken"))
    }
}

/// **The third output has a lamp, and it says what the BOARD said.**
///
/// A hardware monitor that freezes is the failure this exists for: the SRT and
/// NDI legs each had a state an indicator could read, and the SDI leg — the one
/// a director's monitor actually hangs off — had a five-second toast and
/// nothing else. Ten minutes later there was no record anywhere that the
/// picture had stopped.
@MainActor
struct ModelPlayoutLampTests {
    @Test func aStalledBoardReachesTheLampAndTheToast() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.notePlayoutState(.feeding)
            #expect(controller.mirrors.playoutState == .feeding)
            #expect(StreamLink(controller.mirrors.playoutState) == .up)

            controller.notePlayoutState(.stalled(L("playout_refused")))
            #expect(controller.mirrors.playoutState
                    == .stalled(L("playout_refused")),
                    "the lamp did not follow the board")
            #expect(controller.lastError == L("playout_refused"),
                    "the refusal never reached the operator")

            // The toast clears itself in five seconds; the LAMP is the record,
            // and it must not clear until the board says otherwise.
            controller.notePlayoutState(.feeding)
            #expect(controller.mirrors.playoutState == .feeding)
            #expect(controller.lastError == nil,
                    "the board came back and its complaint stayed on screen")
        }
    }

    /// Every sentence the board can put on the line is one the recovery can
    /// take back. The list used to be two `==` comparisons, and the third
    /// sentence — the board refusing a frame — would have stuck to the toast
    /// register for its full five seconds after the board was already fine.
    @Test func everyPlayoutComplaintIsOneTheRecoveryClears() async throws {
        try await ControllerHarness.run { controller, _ in
            for complaint in CaptureController.playoutComplaints {
                controller.lastError = complaint
                controller.notePlayoutState(.feeding)
                #expect(controller.lastError == nil,
                        "a recovered board left \(complaint) on screen")
            }
            // …and nothing else. A message that is somebody else's outranks a
            // resolved stall.
            controller.lastError = "the card is full"
            controller.notePlayoutState(.feeding)
            #expect(controller.lastError == "the card is full")
        }
    }

    /// No board selected is no lamp — the footer is crowded and an operator
    /// who does not use the SDI output should not pay for a control that says
    /// "no monitor" all day.
    @Test func noBoardIsNoLamp() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.monitorDeviceID = nil
            controller.rebuildPlayout()
            #expect(controller.mirrors.playoutState == .off)
            #expect(!StreamLink(controller.mirrors.playoutState).isEngaged)
        }
    }

    /// …but a board that was SELECTED and could not be opened is a lamp in
    /// trouble, not an absent one. The operator picked an output and there is
    /// no picture on it.
    @Test func aSelectedBoardThatWouldNotOpenIsTrouble() async throws {
        let previous = PlayoutFeeder.factory
        PlayoutFeeder.factory = { _, _, _, _ in throw NSError(domain: "t", code: 1) }
        defer { PlayoutFeeder.factory = previous }
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.monitorDeviceID = "decklink:board"
            controller.rebuildPlayout()
            #expect(controller.mirrors.playout == nil, "the fake board opened")
            guard case .trouble = StreamLink(controller.mirrors.playoutState)
            else {
                Issue.record("""
                    a selected board that never opened reads as \
                    \(controller.mirrors.playoutState)
                    """)
                return
            }
        }
    }
}
