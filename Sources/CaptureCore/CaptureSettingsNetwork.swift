import Foundation

// The two ways the app puts itself on the set network. Both are off by default
// and for the same reason: a capture tool does not open a port or announce
// itself on a production's network until somebody asks it to.

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

/// NDI output (see `CNDSender` and `CaptureController+NDI`).
public struct NDISettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled = "ndiEnabled"
        case sourceName = "ndiSourceName"
    }

    /// The viewer is sent out as an NDI source; nil/false — off, which is the
    /// default. Optional, like every added field, so settings written by an
    /// older build still decode.
    public var enabled: Bool?
    /// Name the source is announced under; nil — `CaptureSettings.ndiSourceNameEffective`.
    public var sourceName: String?

    public init() {}
}
