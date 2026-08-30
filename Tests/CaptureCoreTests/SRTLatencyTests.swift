import Foundation
import Testing

@testable import CaptureCore

/// The delivery buffer as a function of the link, which is what makes it not a
/// setting.
struct SRTLatencyTests {
    /// No link, no measurement — and the floor is also the right answer for a
    /// link inside one building, so nothing is lost by not knowing yet.
    @Test func withNoMeasurementItIsTheFloor() {
        #expect(SRTLatency.recommended(forRTT: nil) == SRTLatency.floorMs)
        #expect(SRTLatency.recommended(forRTT: 0) == SRTLatency.floorMs)
        #expect(SRTLatency.recommended(forRTT: .nan) == SRTLatency.floorMs)
        #expect(SRTLatency.recommended(forRTT: .infinity) == SRTLatency.floorMs)
    }

    /// A link inside the building measures a fraction of a millisecond and
    /// still wants room for a burst.
    @Test func aLocalLinkStaysAtTheFloor() {
        #expect(SRTLatency.recommended(forRTT: 0.4) == SRTLatency.floorMs)
        #expect(SRTLatency.recommended(forRTT: 12) == SRTLatency.floorMs)
    }

    /// Over the internet it is four round trips, which is Haivision's own
    /// recommendation for an ordinary link.
    @Test func aWideLinkIsFourRoundTrips() {
        #expect(SRTLatency.recommended(forRTT: 60) == 240)
        #expect(SRTLatency.recommended(forRTT: 150) == 600)
    }

    /// libsrt's ceiling is a real refusal, not a style choice.
    @Test func nothingAsksForMoreThanLibsrtAccepts() {
        #expect(SRTLatency.recommended(forRTT: 100_000)
                == SRTLatency.ceilingMs)
    }

    /// The buffer is negotiated in the handshake, so acting on a new
    /// measurement costs the far end a gap. A link whose RTT wanders by a few
    /// milliseconds must not reconnect on its own.
    @Test func aWanderingRTTDoesNotReconnect() {
        // 240 ms of buffer, measured against an RTT that moves either side of
        // the 60 ms it was built for
        #expect(!SRTLatency.wantsReconnect(current: 240, forRTT: 55))
        #expect(!SRTLatency.wantsReconnect(current: 240, forRTT: 65))
        #expect(!SRTLatency.wantsReconnect(current: 240, forRTT: 71))
        // …and a link that genuinely got worse does
        #expect(SRTLatency.wantsReconnect(current: 240, forRTT: 120))
    }

    /// A link that got BETTER keeps its buffer. Shrinking it would cost a gap
    /// to buy latency nobody asked for, on a link that is working.
    @Test func aLinkThatImprovedIsLeftAlone() {
        #expect(!SRTLatency.wantsReconnect(current: 600, forRTT: 10))
    }
}
