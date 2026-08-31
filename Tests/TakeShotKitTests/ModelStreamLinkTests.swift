import Testing

@testable import TakeShotKit

/// One reading of "is the link up" across two transports that report in their
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
        #expect(StreamLink(SRTOutputState.sending) == .up)
        #expect(StreamLink(NDIOutputState.sending) == .up)
    }

    @Test func offIsTheOnlyStateWithNothingToSay() {
        #expect(!StreamLink(SRTOutputState.off).isEngaged)
        #expect(!StreamLink(NDIOutputState.off).isEngaged)
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
        #expect(srt.map(StreamLink.init).count == srt.count)
        #expect(ndi.map(StreamLink.init).count == ndi.count)
        // Trouble carries what to say about it, in every case that has words.
        #expect(StreamLink(SRTOutputState.reconnecting("cable")) == .trouble("cable"))
        #expect(StreamLink(NDIOutputState.failed("no route")) == .trouble("no route"))
    }
}
