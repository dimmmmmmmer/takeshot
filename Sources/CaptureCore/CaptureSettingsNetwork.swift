import Foundation

// How the app puts itself on the set network. Off by default, and for a reason
// worth stating: a capture tool does not open a port or send a picture out over
// a production's network until somebody asks it to.

/// The browser remote (see `RemoteServer` and `CaptureController+Remote`).
public struct RemoteSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled = "remoteEnabled"
        case port = "remotePort"
        case pin = "remotePIN"
    }

    /// The browser remote is listening; nil/false — off, which is the default.
    public var enabled: Bool?
    /// TCP port for the remote; nil — `portEffective`.
    public var port: Int?
    /// Four digits, generated on first enable and shown in Settings. Stored so
    /// the same code keeps working after a relaunch — a PIN that changed every
    /// launch would have to be re-read off the laptop mid-take.
    ///
    /// The persisted key is `remotePIN` and has to stay spelled that way for a
    /// second reason beyond the stored blob: `DiagnosticsRedaction` drops
    /// secrets by matching the key NAME, so this is what keeps the PIN out of a
    /// diagnostics bundle that gets emailed to someone.
    public var pin: String?

    public init() {}

    /// Port the remote actually binds. 8765 is unassigned by IANA and outside
    /// the range macOS hands out as an ephemeral port, so it does not collide
    /// with a client socket the machine opened first.
    public var portEffective: Int {
        guard let port, (1024...65535).contains(port) else { return 8765 }
        return port
    }
}

// `ndiEnabled` and `ndiSourceName` were a group here. They are gone from the
// record, not merely unread: the NDI output is gone and there is no feature for
// a stored switch or a stored source name to mean anything to. A blob that still
// carries either key decodes exactly as before — the synthesized decoder drops
// keys it does not know, which is what makes removing one safe — and this build
// writes it back without them.
//
// No `RetiredSettings` entry and no schema bump, deliberately, for the reason
// `captureBitDepth` did not get one either: that pair exists for a field a
// MIGRATION has to read once, and there is nowhere for these to be read into.
// The SRT output that replaces the feature needs an address, a port and a role,
// and a source NAME answers none of those questions — carrying it across would
// be inventing a value rather than preserving one. An operator who had NDI on
// gets SRT off, and configures it. `anOldBlobWithRetiredNDIKeysStillDecodes`
// holds the half of the contract that is real.
