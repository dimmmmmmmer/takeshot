import Foundation
import Testing

@testable import CaptureCore

/// What an operator may type into the SRT address field.
///
/// SRT has no URL — host, port and role are three separate parameters, and
/// this app had three controls. Every other tool an operator has met takes one
/// string: OBS, ffmpeg and libsrt's own utilities all want
/// `srt://host:port?mode=caller`, which is why the mode reads as a setting OBS
/// does not have (owner: "в обс такой настройки я не видел почему то" — it is
/// in the URL there). So the field takes what those take.
struct SRTAddressTests {
    @Test func aBareHostNamesNothingElse() throws {
        let parsed = try #require(SRTAddress.parse("192.168.1.50"))
        #expect(parsed.host == "192.168.1.50")
        // Nil rather than a default: a paste that names only the host must not
        // reset a port the operator set on purpose.
        #expect(parsed.port == nil)
        #expect(parsed.mode == nil)
    }

    @Test func hostAndPortSplitAtTheLastColon() throws {
        let parsed = try #require(SRTAddress.parse("cart.local:9000"))
        #expect(parsed.host == "cart.local")
        #expect(parsed.port == 9000)
    }

    @Test func theSchemeAndThePathAreDropped() throws {
        let parsed = try #require(SRTAddress.parse("srt://10.0.0.9:1234/live"))
        #expect(parsed.host == "10.0.0.9")
        #expect(parsed.port == 1234)
    }

    /// The query is where the other two controls are hiding in every tool an
    /// operator already uses.
    @Test func theQueryCarriesTheModeAndTheBuffer() throws {
        let parsed = try #require(SRTAddress.parse(
            "srt://1.2.3.4:9000?mode=listener&latency=320&passphrase=hunter2"))
        #expect(parsed.mode == "listener")
        #expect(parsed.latencyMs == 320)
        #expect(parsed.passphrase == "hunter2")
    }

    /// libsrt spells the delivery buffer three ways depending on which side is
    /// being configured, and all three mean this link's buffer.
    @Test func theThreeSpellingsOfLatencyAllArrive() throws {
        for key in ["latency", "rcvlatency", "peerlatency"] {
            let parsed = try #require(SRTAddress.parse("h:9000?\(key)=250"))
            #expect(parsed.latencyMs == 250, "\(key) was not read")
        }
    }

    /// The case a plain `split(":")` gets wrong: an IPv6 literal's own colons
    /// are not separators.
    @Test func anIPv6LiteralKeepsItsColons() throws {
        let bracketed = try #require(SRTAddress.parse("[fe80::1]:9000"))
        #expect(bracketed.host == "fe80::1")
        #expect(bracketed.port == 9000)
        let bare = try #require(SRTAddress.parse("fe80::1"))
        #expect(bare.host == "fe80::1")
        #expect(bare.port == nil, "an address's own colon was read as a port")
    }

    /// A port outside what can be opened is not a port. Answering nil leaves
    /// whatever was set rather than failing the open with a number the
    /// operator never meant to ask for.
    @Test func anImpossiblePortIsNotRead() throws {
        #expect(try #require(SRTAddress.parse("h:70000")).port == nil)
        #expect(try #require(SRTAddress.parse("h:80")).port == nil)
        #expect(try #require(SRTAddress.parse("h:abc")).port == nil)
    }

    @Test func nothingAtAllIsNothing() {
        #expect(SRTAddress.parse("") == nil)
        #expect(SRTAddress.parse("   ") == nil)
        #expect(SRTAddress.parse("srt://") == nil)
    }
}
