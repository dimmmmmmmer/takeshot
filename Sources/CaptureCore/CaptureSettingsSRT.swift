import Foundation

/// Which end of the SRT handshake this app is.
///
/// The one setting NDI had no equivalent of, and the reason SRT needed a design
/// rather than a rename. NDI announced itself and a receiver picked it out of a
/// list. SRT is a transport: somebody has to dial, and which side can dial is a
/// fact about the venue's network rather than a preference.
public enum SRTRole: String, CaseIterable, Codable, Sendable {
    /// This Mac dials the receiver. Works when the Mac is behind NAT and the
    /// receiver is reachable — the common case on a set, and the default.
    case caller
    /// This Mac waits for the receiver to dial in. Works the other way round.
    case listener

    /// What a stored string means, including nil and including a spelling from a
    /// build that offered a third one.
    public static func resolved(_ raw: String?) -> SRTRole {
        guard let raw, let role = SRTRole(rawValue: raw) else { return .caller }
        return role
    }
}

/// Everything needed to open one link, resolved — nothing optional, nothing to
/// interpret.
///
/// Its own value type rather than five arguments, for two reasons. The mirror
/// compares it to decide whether a settings write is a reconfiguration or
/// nothing at all, which needs `Equatable` over the whole of it; and the effective
/// values live in exactly one place instead of being re-derived at the socket.
public struct SRTEndpoint: Equatable, Sendable {
    public var role: SRTRole
    /// Host or address. Empty for a listener, which binds every interface.
    public var address: String
    public var port: Int
    /// SRT's delivery buffer, in milliseconds.
    public var latencyMs: Int
    /// nil means unencrypted, which is what an empty field means.
    public var passphrase: String?

    public init(role: SRTRole, address: String, port: Int, latencyMs: Int,
                passphrase: String?) {
        self.role = role
        self.address = address
        self.port = port
        self.latencyMs = latencyMs
        self.passphrase = passphrase
    }

    /// How the status row names this link. `srt://` because that is the URL every
    /// receiver on a set is typed into, so it is the string an operator can read
    /// back to whoever is at the other end.
    public var url: String {
        role == .listener ? "srt://:\(port)" : "srt://\(address):\(port)"
    }
}

/// The SRT output (see `CSRTSender`, `SRTMirror` and
/// `CaptureController+SRT`).
///
/// Seven fields, and the shortlist is the design. NDI needed a switch and a name;
/// SRT needs to be told WHERE to send, in WHICH role, how much of a bad link to
/// ride out, and how many bits the link can carry — none of which the app can
/// know and all of which the operator does. Everything else about the stream is
/// inferred and stays inferred: the codec (H.264, because every receiver decodes
/// it), the keyframe interval (one second, because that is the join time), the
/// raster and the frame rate (the signal's), and the packet size (188 × 7,
/// because that is what MPEG-TS over SRT is).
public struct SRTSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled = "srtEnabled"
        case role = "srtRole"
        case address = "srtAddress"
        case port = "srtPort"
        case latencyMs = "srtLatencyMs"
        case bitrateMbps = "srtBitrateMbps"
        case passphrase = "srtPassphrase"
    }

    /// The viewer is sent out over SRT; nil/false — off, which is the default.
    /// Optional, like every added field, so settings written by an older build
    /// still decode.
    public var enabled: Bool?
    /// "caller" or "listener"; nil — caller.
    public var role: String?
    /// Where a caller dials. Ignored by a listener.
    public var address: String?
    /// nil — `portEffective`.
    public var port: Int?
    /// nil — `latencyEffective`.
    public var latencyMs: Int?
    /// nil — `bitrateEffective`.
    public var bitrateMbps: Double?
    /// AES passphrase, ten characters or more, or nil/empty for an unencrypted
    /// link.
    ///
    /// The persisted key is `srtPassphrase` and has to stay spelled that way for
    /// the reason `remotePIN` does: `DiagnosticsRedaction` drops credentials by
    /// matching the key NAME, and this is what keeps it out of a diagnostics
    /// bundle that gets emailed to someone.
    public var passphrase: String?

    public init() {}

    // MARK: - what the app actually opens

    public var roleEffective: SRTRole { SRTRole.resolved(role) }

    /// 9000 is the port every SRT example and every receiver's placeholder uses,
    /// it is unassigned by IANA, and it is outside the range macOS hands out as
    /// an ephemeral port — so it does not collide with a client socket the machine
    /// opened first. Same three reasons the remote's 8765 was chosen.
    public var portEffective: Int {
        guard let port, (1024...65535).contains(port) else { return 9000 }
        return port
    }

    /// **The number this feature is actually about.** SRT's delivery buffer is the
    /// window it has to notice a lost packet and ask for it again, so it is how
    /// much of a bad link the picture rides out — and it is paid for in delay,
    /// which is why it cannot simply be set high and forgotten.
    ///
    /// 120 ms is libsrt's own live default and the figure the protocol's own
    /// guidance starts from: about four times a typical round trip on a venue
    /// LAN, which is enough for a retransmission to arrive in time. The floor is
    /// 20 (below one round trip, SRT cannot recover anything and the operator has
    /// bought delay for nothing) and the ceiling 8000 (libsrt's own limit).
    public var latencyEffective: Int {
        guard let latencyMs, (20...8000).contains(latencyMs) else { return 120 }
        return latencyMs
    }

    /// Mbit/s the encoder aims at. 8 is a 1080p monitoring picture that holds up
    /// on a face; the range is a 0.5 phone-tethered feed to a 100 Mbit/s wired
    /// one.
    public var bitrateEffective: Double {
        guard let bitrateMbps, (0.5...100).contains(bitrateMbps) else { return 8 }
        return bitrateMbps
    }

    public var bitsPerSecondEffective: Int {
        Int((bitrateEffective * 1_000_000).rounded())
    }

    public var addressEffective: String {
        address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The passphrase length libsrt accepts, in BYTES. Not ours — it refuses
    /// anything outside 10…79 as firmly either way, so the app checks the same
    /// rule first in order to say so in the operator's own language rather
    /// than passing on a socket error.
    ///
    /// **Bytes and not `Character`s**, which is what this counted before: the
    /// bridge hands libsrt a C string, so a Cyrillic passphrase is twice the
    /// length `String.count` reports — ten Cyrillic letters passed a check
    /// libsrt would then measure as twenty bytes, and forty of them would have
    /// been refused by the socket for a reason the app never named.
    public static let passphraseMinimum = 10
    /// …and the longest. The half of libsrt's rule the app did not implement:
    /// an operator who pasted an 80-character phrase got the socket's own
    /// English back instead of a sentence in their language.
    public static let passphraseMaximum = 79

    /// nil for an unencrypted link, which is what an empty field means. A
    /// passphrase that is too SHORT is not nil and not silently dropped either —
    /// see `configurationProblem`.
    public var passphraseEffective: String? {
        let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What is wrong with this configuration, as something the UI can put words
    /// to; nil when there is nothing wrong.
    ///
    /// Three cases, and each is a silent failure if it is not checked here. A
    /// caller with no address would dial nowhere and report a resolver error
    /// nobody can act on; a passphrase outside libsrt's range would be refused
    /// deep inside an open, and an operator who typed one and got an
    /// unencrypted stream would have no way of knowing.
    ///
    /// An EMPTY passphrase is none of them: it means "no encryption", which is
    /// what `passphraseEffective` answers nil for, and it reaches the socket
    /// as an unencrypted link by design.
    public enum Problem: Equatable, Sendable {
        case addressMissing
        case passphraseTooShort
        case passphraseTooLong
    }

    public var configurationProblem: Problem? {
        if roleEffective == .caller, addressEffective.isEmpty {
            return .addressMissing
        }
        if let phrase = passphraseEffective {
            let bytes = phrase.utf8.count
            if bytes < Self.passphraseMinimum { return .passphraseTooShort }
            if bytes > Self.passphraseMaximum { return .passphraseTooLong }
        }
        return nil
    }

    /// The link to open, or nil when `configurationProblem` says there is not one.
    public var endpoint: SRTEndpoint? {
        guard configurationProblem == nil else { return nil }
        return SRTEndpoint(role: roleEffective, address: addressEffective,
                           port: portEffective, latencyMs: latencyEffective,
                           passphrase: passphraseEffective)
    }
}
