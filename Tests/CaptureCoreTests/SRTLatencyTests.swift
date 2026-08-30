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

/// libsrt's passphrase rule, both halves of it, in the unit the socket
/// measures.
struct SRTPassphraseTests {
    private func settings(_ phrase: String?) -> SRTSettings {
        var srt = SRTSettings()
        srt.role = "listener"     // no address needed, so only the phrase is asked about
        srt.passphrase = phrase
        return srt
    }

    /// Empty means NO ENCRYPTION and always did — the operator's suspicion was
    /// that this was broken, and it is the one part that was right.
    @Test func anEmptyPassphraseIsNoEncryptionAndNoComplaint() {
        for empty in [nil, "", "   "] {
            let srt = settings(empty)
            #expect(srt.passphraseEffective == nil, "\(empty ?? "nil") is not nil")
            #expect(srt.configurationProblem == nil,
                    "an unencrypted link was refused for \(empty ?? "nil")")
        }
    }

    /// **Bytes, not characters.** The bridge hands libsrt a C string, so ten
    /// Cyrillic letters are twenty bytes — and the old check, which counted
    /// `Character`s, passed a phrase the socket would have measured
    /// differently at both ends of the range.
    @Test func theLengthIsMeasuredInBytes() {
        // five Cyrillic letters: 5 characters, 10 bytes — long enough
        let short = settings("ПАРОЛ")
        #expect(short.passphraseEffective?.count == 5)
        #expect(short.configurationProblem == nil,
                "10 bytes was refused because it is 5 characters")
        // forty of them: 40 characters, 80 bytes — one over libsrt's ceiling
        let long = settings(String(repeating: "П", count: 40))
        #expect(long.configurationProblem == .passphraseTooLong,
                "80 bytes was accepted because it is 40 characters")
    }

    @Test func bothEndsOfTheRangeAreChecked() {
        #expect(settings(String(repeating: "a", count: 9)).configurationProblem
                == .passphraseTooShort)
        #expect(settings(String(repeating: "a", count: 10)).configurationProblem == nil)
        #expect(settings(String(repeating: "a", count: 79)).configurationProblem == nil)
        #expect(settings(String(repeating: "a", count: 80)).configurationProblem
                == .passphraseTooLong)
    }
}
