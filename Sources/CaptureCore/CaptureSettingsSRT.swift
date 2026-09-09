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
    /// Whether `latencyMs` was STATED rather than derived.
    ///
    /// The two are told apart because only one of them may be overwritten by a
    /// measurement. A derived figure is the app's own starting guess and
    /// `SRTMirror` replaces it with what the link reports; a stated one comes
    /// from a pasted `srt://…?latency=` URL, which is the receiving end saying
    /// what it wants — and both ends of an SRT link have to agree on the
    /// buffer, so that is not a number to improve on.
    public var latencyIsExplicit: Bool
    /// nil means unencrypted, which is what an empty field means.
    public var passphrase: String?
    /// What a gateway routes by — MediaMTX, SRS, Haivision, Wowza all pick the
    /// publishing point from it (`publish/cam1`, or libsrt's own
    /// `#!::r=live/cam1` form). Set on the socket before the handshake; nil
    /// sends none, which a plain receiver never asks for.
    public var streamID: String?

    public init(role: SRTRole, address: String, port: Int, latencyMs: Int,
                latencyIsExplicit: Bool = false, passphrase: String?,
                streamID: String? = nil) {
        self.role = role
        self.address = address
        self.port = port
        self.latencyMs = latencyMs
        self.latencyIsExplicit = latencyIsExplicit
        self.passphrase = passphrase
        self.streamID = streamID
    }

    /// How the status row names this link. `srt://` because that is the URL every
    /// receiver on a set is typed into, so it is the string an operator can read
    /// back to whoever is at the other end.
    ///
    /// **Encryption is named, and it is the only field here that has to be.**
    /// The passphrase is typed into a `SecureField`, so a value left in it from
    /// an earlier experiment is invisible — and an encrypted socket dialled at
    /// a plain endpoint is refused at the handshake and comes back as a link
    /// loss, which reads as "nobody has opened the stream yet". The operator
    /// spent an evening on a link that could never come up with nothing on
    /// screen naming the reason. The PASSPHRASE is not printed, only the fact
    /// that there is one: this string is read out loud to whoever is at the
    /// other end.
    public var url: String {
        let base = role == .listener ? "srt://:\(port)" : "srt://\(address):\(port)"
        var text = base
        if let streamID { text += "?streamid=" + streamID }
        if passphrase?.isEmpty == false { text += " · AES" }
        return text
    }
}

/// The SRT output (see `CSRTSender`, `SRTMirror` and
/// `CaptureController+SRT`).
///
/// Eight fields, and the shortlist is the design. NDI needed a switch and a name;
/// SRT needs to be told WHERE to send, in WHICH role, how much of a bad link to
/// ride out, how many bits the link can carry, and — for a gateway that routes
/// by it — which stream this is; none of which the app can know and all of
/// which the operator does. Everything else about the stream is
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
        case streamID = "srtStreamID"
        case codec = "srtCodec"
        case profile = "srtProfile"
        case rateControl = "srtRateControl"
        case keyframeSeconds = "srtKeyframeSeconds"
        case bFrames = "srtBFrames"
    }

    /// **The encoder's five dials** (owner: "я бы хотел чтобы… выбирать
    /// энкодер, кодек и настройку цвета. у энкодера там профиль выбрать типа,
    /// абр цбр, кейфреймы б фреймы, в общем что посчитаешь нужным для
    /// кастомизации но чтобы не перегружать пользователя").
    ///
    /// Every one of them is nil at the value the encoder has always used, so a
    /// stream set up before these existed is byte-for-byte the stream it was.
    /// What is deliberately NOT here is the colour: the tags follow the signal
    /// (`Configuration.colorPreset`), and a hand-set primary on the wire is a
    /// picture that is wrong at the far end with nothing on this one to say so.
    ///
    /// The video codec (`SRTVideoCodec`); nil — H.264, which every decoder
    /// opens.
    public var codec: String?
    /// H.264/HEVC profile (`SRTEncoderProfile`); nil — High, which is what the
    /// encoder has always asked for.
    public var profile: String?
    /// Average or constant bitrate (`SRTRateControl`); nil — average.
    public var rateControl: String?
    /// Seconds between keyframes; nil — 1, which is how long a receiver waits
    /// to join and how long a frozen picture takes to come back.
    public var keyframeSeconds: Int?
    /// Let the encoder reorder frames (B-frames); nil/false — no.
    ///
    /// Off by default and worth staying off for a monitoring feed: reordering
    /// buys bitrate at the cost of a frame of latency, and this link exists so
    /// somebody can call action off it.
    public var bFrames: Bool?

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
    /// The gateway's stream ID; nil or empty sends none (see
    /// `SRTEndpoint.streamID`). A pasted `srt://…?streamid=` fills it.
    public var streamID: String?

    public init() {}

    // MARK: - what the app actually opens

    public var roleEffective: SRTRole { SRTRole.resolved(role) }

    // MARK: - the encoder's dials, resolved

    public var codecEffective: SRTVideoCodec {
        codec.flatMap(SRTVideoCodec.init(rawValue:)) ?? .h264
    }

    public var profileEffective: SRTEncoderProfile {
        profile.flatMap(SRTEncoderProfile.init(rawValue:)) ?? .high
    }

    public var rateControlEffective: SRTRateControl {
        rateControl.flatMap(SRTRateControl.init(rawValue:)) ?? .average
    }

    /// Seconds between keyframes, held to a range a monitoring feed can live
    /// with: under one a receiver spends the link on parameter sets, and over
    /// ten a director watching a frozen frame waits ten seconds for it to come
    /// back.
    public var keyframeSecondsEffective: Int {
        min(10, max(1, keyframeSeconds ?? 1))
    }

    public var bFramesEffective: Bool { bFrames ?? false }

    /// **The whole link as one URL — the only thing the settings pane asks
    /// for.**
    ///
    /// Port, connection type and stream ID are not settings; they are parts of
    /// an address, and an operator who has been handed one has been handed all
    /// of them at once (owner: "и все еще тут есть порт, delivery buffer и
    /// connection type — обсуждали же что это не настройки", and of the paste
    /// being split across fields: "это скорее минус чем плюс"). This composes
    /// what `SRTAddress.parse` takes apart, so what the field shows is what a
    /// paste would have said.
    ///
    /// Only the non-default parts are spelled out. A caller does not carry
    /// `mode=caller` — it is the default, and a URL that stated it would differ
    /// from the one the operator pasted for no reason they could see. The
    /// passphrase is never composed in: it is a secret with a field of its own,
    /// and this string is on screen.
    public var addressURL: String {
        let host = address ?? ""
        var text = "srt://" + host + ":\(portEffective)"
        var query: [String] = []
        if roleEffective == .listener { query.append("mode=listener") }
        if let streamID, !streamID.isEmpty { query.append("streamid=" + streamID) }
        if latencyMs != nil { query.append("latency=\(latencyEffective)") }
        if !query.isEmpty { text += "?" + query.joined(separator: "&") }
        return text
    }

    /// 9000 is the port every SRT example and every receiver's placeholder uses,
    /// it is unassigned by IANA, and it is outside the range macOS hands out as
    /// an ephemeral port — so it does not collide with a client socket the machine
    /// opened first. Same three reasons the remote's 8765 was chosen.
    public var portEffective: Int {
        guard let port, (1024...65535).contains(port) else { return 9000 }
        return port
    }

    /// **The buffer to OPEN with, which is a starting point and not a
    /// setting.** SRT's delivery buffer is the window it has to notice a lost
    /// packet and ask for it again, so it is how much of a bad link the picture
    /// rides out — and it is paid for in delay, which is why it cannot simply
    /// be set high and forgotten.
    ///
    /// Nothing puts this number in front of the operator (owner: "пусть это не
    /// на пользователе будет а автоматом считается"): the right value is four
    /// round trips, the round trip is something the LINK measures and reports,
    /// and asking somebody on set to know it in milliseconds about a network
    /// they did not build is asking them to guess at a number the app is
    /// holding. `SRTMirror` reads the measurement and re-opens on it;
    /// `SRTLatency` is the arithmetic between the two.
    ///
    /// `SRTLatency.floorMs` is what a link starts on, before it has been
    /// measured — libsrt's own live default, and enough for a venue LAN. A
    /// value from a pasted URL is kept as stated, within libsrt's own limits.
    public var latencyEffective: Int {
        guard let latencyMs, (20...8000).contains(latencyMs) else {
            return SRTLatency.floorMs
        }
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
    /// libsrt's own ceiling for `SRTO_STREAMID`.
    public static let streamIDMaximum = 512

    public var streamIDEffective: String? {
        let trimmed = streamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public enum Problem: Equatable, Sendable {
        case addressMissing
        case passphraseTooShort
        case passphraseTooLong
        case streamIDTooLong
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
        if let streamID = streamIDEffective,
           streamID.utf8.count > Self.streamIDMaximum {
            return .streamIDTooLong
        }
        return nil
    }

    /// The link to open, or nil when `configurationProblem` says there is not one.
    public var endpoint: SRTEndpoint? {
        guard configurationProblem == nil else { return nil }
        return SRTEndpoint(role: roleEffective, address: addressEffective,
                           port: portEffective, latencyMs: latencyEffective,
                           latencyIsExplicit: latencyMs != nil,
                           passphrase: passphraseEffective,
                           streamID: streamIDEffective)
    }
}

/// The codec an SRT feed is encoded in.
///
/// Two, and no more: H.264 is what every decoder in a venue opens, and HEVC
/// halves the bitrate for a receiver that can take it. The heavier things this
/// app can record in are not stream codecs.
public enum SRTVideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"

    public var id: String { rawValue }
}

/// How much the encoder is allowed to do to the picture.
///
/// Baseline exists for the receiver that cannot take anything else — an old
/// hardware decoder, a browser on a locked-down machine — and costs bitrate
/// for it. High is what the encoder has always asked for.
public enum SRTEncoderProfile: String, CaseIterable, Identifiable, Sendable {
    case baseline
    case main
    case high

    public var id: String { rawValue }

    /// `Localizable.strings` key. Written out rather than assembled from the
    /// raw value, for the reason `CountedNoun` states.
    public var labelKey: String {
        switch self {
        case .baseline: return "srt_profile_baseline"
        case .main: return "srt_profile_main"
        case .high: return "srt_profile_high"
        }
    }
}

/// Whether the encoder may spend more on a hard second than an easy one.
///
/// Average is the default and the right answer on most links: the picture
/// keeps its quality and the rate evens out. Constant is for a link that is
/// rented by the bit — a venue's uplink with a hard ceiling — where a burst
/// costs more than the quality it buys.
public enum SRTRateControl: String, CaseIterable, Identifiable, Sendable {
    case average
    case constant

    public var id: String { rawValue }

    public var labelKey: String {
        switch self {
        case .average: return "srt_rate_average"
        case .constant: return "srt_rate_constant"
        }
    }
}
