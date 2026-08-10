import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What the operator's four fields mean once they are resolved, and the two
/// mistakes that are caught before a socket is opened.
@Suite struct SRTSettingsFieldTests {
    @Test func theSwitchIsOffInAFreshInstall() {
        let settings = CaptureSettings()
        #expect(settings.srt.enabled == nil)
        #expect(settings.srt.role == nil)
        #expect(settings.srt.address == nil)
        #expect(settings.srt.passphrase == nil)
    }

    /// The defaults an operator gets without touching anything: dial out, on the
    /// port every SRT receiver's placeholder shows, with libsrt's own live
    /// latency and a bitrate that holds up on a face at 1080p.
    @Test func theDefaultsAreTheOnesAReceiverExpects() {
        let settings = CaptureSettings()
        #expect(settings.srt.roleEffective == SRTRole.caller)
        #expect(settings.srt.portEffective == 9000)
        #expect(settings.srt.latencyEffective == 120)
        #expect(settings.srt.bitrateEffective == 8.0)
        #expect(settings.srt.bitsPerSecondEffective == 8_000_000)
    }

    /// A value outside what libsrt or the network layer accepts falls back rather
    /// than being passed on: an out-of-range option is refused at the socket, and
    /// "SRT option 23 refused" is not something an operator can act on.
    @Test func anOutOfRangeFieldFallsBackToTheDefault() {
        var settings = CaptureSettings()
        for port in [0, 80, 65_536, -1] {
            settings.srt.port = port
            #expect(settings.srt.portEffective == 9000, "port \(port) got through")
        }
        for latency in [0, 19, 8001, -5] {
            settings.srt.latencyMs = latency
            #expect(settings.srt.latencyEffective == 120,
                    "latency \(latency) got through")
        }
        for bitrate in [0.0, 0.4, 101.0, -3.0] {
            settings.srt.bitrateMbps = bitrate
            #expect(settings.srt.bitrateEffective == 8.0,
                    "bitrate \(bitrate) got through")
        }
    }

    @Test func anUnknownRoleReadsAsCaller() {
        #expect(SRTRole.resolved(nil) == SRTRole.caller)
        #expect(SRTRole.resolved("rendezvous") == SRTRole.caller)
        #expect(SRTRole.resolved("listener") == SRTRole.listener)
        #expect(SRTRole.resolved("caller") == SRTRole.caller)
    }

    /// A caller with no address is a link that would dial nowhere. Caught here so
    /// the operator is told in their own language rather than handed a resolver
    /// error.
    @Test func aCallerWithNoAddressIsAProblemAndNotAnEndpoint() {
        var settings = CaptureSettings()
        settings.srt.enabled = true
        #expect(settings.srt.configurationProblem == SRTSettings.Problem.addressMissing)
        #expect(settings.srt.endpoint == nil)
        settings.srt.address = "   "
        #expect(settings.srt.configurationProblem == SRTSettings.Problem.addressMissing)
        settings.srt.address = "srt.example.com"
        #expect(settings.srt.configurationProblem == nil)
        #expect(settings.srt.endpoint?.address == "srt.example.com")
    }

    /// A listener needs no address at all: it binds every interface, so a field
    /// left blank is correct rather than incomplete.
    @Test func aListenerNeedsNoAddress() {
        var settings = CaptureSettings()
        settings.srt.role = SRTRole.listener.rawValue
        #expect(settings.srt.configurationProblem == nil)
        let endpoint = settings.srt.endpoint
        #expect(endpoint?.role == SRTRole.listener)
        #expect(endpoint?.url == "srt://:9000")
    }

    /// **A short passphrase is a problem and not a silent downgrade.** SRT
    /// refuses anything under ten characters, so an operator who typed five would
    /// otherwise get an unencrypted stream and no way of knowing.
    @Test func aPassphraseTooShortIsReportedRatherThanDropped() {
        var settings = CaptureSettings()
        settings.srt.address = "10.0.0.9"
        settings.srt.passphrase = "shortish"
        #expect(SRTSettings.passphraseMinimum == 10)
        #expect(settings.srt.configurationProblem
            == SRTSettings.Problem.passphraseTooShort)
        #expect(settings.srt.endpoint == nil)
        // Empty is not short — it is "no encryption", which is a choice.
        settings.srt.passphrase = ""
        #expect(settings.srt.configurationProblem == nil)
        #expect(settings.srt.endpoint?.passphrase == nil)
        settings.srt.passphrase = "video-village"
        #expect(settings.srt.endpoint?.passphrase == "video-village")
    }

    /// The URL is what an operator reads out to whoever is at the other end, so
    /// it is spelled the way a receiver is typed.
    @Test func theEndpointNamesItselfAsAReceiverWouldBeTyped() {
        let caller = SRTEndpoint(role: .caller, address: "10.0.4.21", port: 9312,
                                 latencyMs: 200, passphrase: nil)
        #expect(caller.url == "srt://10.0.4.21:9312")
        let listener = SRTEndpoint(role: .listener, address: "", port: 9000,
                                   latencyMs: 120, passphrase: nil)
        #expect(listener.url == "srt://:9000")
    }
}
