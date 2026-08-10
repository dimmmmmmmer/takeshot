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

/// The retired NDI output.
///
/// INERT: the bridge, the mirror, the settings section and the controller
/// extension are all gone, and nothing reads either field any more. It is still
/// on the record for one commit because removing a key is a change to the
/// ON-DISK FORMAT — see `SettingsFormatFixture` for what that costs when it goes
/// wrong — and the two changes are worth reading apart. Removed in the commit
/// that follows this one.
public struct NDISettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled = "ndiEnabled"
        case sourceName = "ndiSourceName"
    }

    public var enabled: Bool?
    public var sourceName: String?

    public init() {}
}
