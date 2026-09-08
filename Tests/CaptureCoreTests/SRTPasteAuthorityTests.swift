import Foundation
import Testing

@testable import CaptureCore

/// **What a pasted SRT URL is allowed to say about the link.**
///
/// Every field the paste fills in is additive on purpose — a bare `host:port`
/// must not reset a port somebody set deliberately — with one exception, and
/// this suite is the exception. A URL that carries a query and no
/// `passphrase=` states that the link is UNENCRYPTED; that is what ffmpeg, OBS
/// and libsrt's own tools mean by it.
///
/// It cost an evening. A passphrase left in the field from an earlier
/// experiment survived the paste of a plain MediaMTX publish URL, so the app
/// dialled with AES-128 at an endpoint expecting none. libsrt refuses that at
/// the handshake, the bridge files every connect refusal as a link loss, and a
/// link loss is retried for ever behind a "Reconnecting" row with no toast —
/// which is indistinguishable from a receiver nobody has opened yet (owner:
/// "и все равно не работает").
@Suite struct SRTPasteAuthorityTests {
    private let mediaMTX = "srt://192.168.1.119:8890?streamid=publish:live:admin:"
        + "14190b05fadd3bf5b8fad550600c686ccf79224b3939c3e0"

    /// The owner's own URL, taken apart. Everything lands, colons in the
    /// streamid included — the parser was never the problem.
    @Test func theOwnersPublishURLIsTakenApartWhole() throws {
        let parsed = try #require(SRTAddress.parse(mediaMTX))
        #expect(parsed.host == "192.168.1.119")
        #expect(parsed.port == 8890)
        #expect(parsed.streamID
                == "publish:live:admin:14190b05fadd3bf5b8fad550600c686ccf79224b3939c3e0")
        #expect(parsed.passphrase == nil)
        #expect(parsed.hadQuery, Comment(rawValue: "the query was not noticed, "
            + "so the paste cannot say the link is unencrypted"))
    }

    /// A URL with a query and no passphrase says so, and the caller can tell
    /// that from a URL that never mentioned the subject.
    @Test func aQueryWithNoPassphraseIsAStatementAndABareHostIsNot() throws {
        #expect(try #require(SRTAddress.parse(mediaMTX)).hadQuery)
        #expect(try #require(SRTAddress.parse("srt://10.0.0.4:9000?mode=caller"))
            .hadQuery)
        // no query at all: the paste says nothing about encryption, and the
        // field keeps whatever was in it
        #expect(!(try #require(SRTAddress.parse("10.0.0.4:9000")).hadQuery))
        #expect(!(try #require(SRTAddress.parse("srt://10.0.0.4")).hadQuery))
    }

    /// A URL that DOES name one still carries it through.
    @Test func aPassphraseInTheURLStillLands() throws {
        let parsed = try #require(
            SRTAddress.parse("srt://10.0.0.4:9000?passphrase=hunter2hunter2"))
        #expect(parsed.passphrase == "hunter2hunter2")
        #expect(parsed.hadQuery)
    }

    /// **The address composes back into what was pasted.** The field shows one
    /// URL and `SRTAddress.parse` takes it apart; if the two disagreed, an
    /// operator who pasted a line and looked at it again would see a different
    /// one (owner, of the old behaviour: "разложило мне все по разным полям
    /// (это скорее минус чем плюс)").
    @Test func theAddressComposesBackIntoWhatWasPasted() throws {
        var srt = SRTSettings()
        let parsed = try #require(SRTAddress.parse(mediaMTX))
        srt.address = parsed.host
        srt.port = parsed.port
        srt.streamID = parsed.streamID

        #expect(srt.addressURL == mediaMTX, "composed \(srt.addressURL)")
    }

    /// A caller does not spell out `mode=caller`: it is the default, and a URL
    /// that stated it would differ from the one the operator pasted for no
    /// reason they could see.
    @Test func aCallerDoesNotSpellOutTheDefaultMode() {
        var srt = SRTSettings()
        srt.address = "10.0.0.4"
        srt.port = 9000

        #expect(srt.addressURL == "srt://10.0.0.4:9000")
        #expect(!srt.addressURL.contains("mode="))
    }

    /// **A listener is an address with no host.** The connection type is part
    /// of the URL now rather than a picker, so this spelling is the only way
    /// to ask for one — and it is the spelling ffmpeg and libsrt's own tools
    /// use.
    @Test func aListenerIsAnAddressWithNoHost() throws {
        var srt = SRTSettings()
        srt.port = 8890
        srt.role = SRTRole.listener.rawValue
        #expect(srt.addressURL == "srt://:8890?mode=listener")

        let parsed = try #require(SRTAddress.parse("srt://:8890?mode=listener"))
        #expect(parsed.host.isEmpty)
        #expect(parsed.port == 8890)
        #expect(parsed.mode == SRTRole.listener.rawValue)
    }

    /// …and a string with neither a host nor a port is still nothing at all.
    @Test func nothingIsStillNothing() {
        #expect(SRTAddress.parse("") == nil)
        #expect(SRTAddress.parse("srt://") == nil)
        #expect(SRTAddress.parse("   ") == nil)
    }

    /// **The status row says when the link is encrypted.** The passphrase is
    /// typed into a `SecureField`, so a stale one is invisible; this line is
    /// the only place an operator could have seen it. The passphrase itself is
    /// never printed — the row is read out loud to the other end.
    @Test func theStatusRowNamesEncryptionWithoutNamingTheSecret() {
        let plain = SRTEndpoint(role: .caller, address: "10.0.0.4", port: 9000,
                                latencyMs: 120, passphrase: nil,
                                streamID: "live")
        let secret = SRTEndpoint(role: .caller, address: "10.0.0.4", port: 9000,
                                 latencyMs: 120, passphrase: "hunter2hunter2",
                                 streamID: "live")

        #expect(!plain.url.contains("AES"))
        #expect(secret.url.contains("AES"), "an encrypted link is not named")
        #expect(!secret.url.contains("hunter2"), "the passphrase is on screen")
        // …and the rest of the row is unchanged by it
        #expect(secret.url.hasPrefix(plain.url))
    }
}
