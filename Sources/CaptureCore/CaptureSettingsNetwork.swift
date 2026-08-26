import Foundation

// The two ways the app puts itself on the set network that keep their own
// settings group. Both are off by default and for the same reason: a capture
// tool does not open a port or announce itself on a production's network until
// somebody asks it to.
//
// The SRT output is the third and has a file of its own (`CaptureSettingsSRT`),
// because seven fields and their effective values are more than a neighbour.

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

/// The NDI output (see `CNDSender`, `NDIVideoMirror` and
/// `CaptureController+NDI`).
///
/// **These two keys have been off the record and are back on it**, which is the
/// case the "make every added field Optional" rule exists for and the one it had
/// never actually been through. The owner dropped NDI in favour of SRT, the keys
/// went with the feature, and then the owner asked for NDI back BESIDE SRT — so
/// three blob shapes are now in the wild and all three have to decode:
///
/// - written before the removal: carries `ndiEnabled`/`ndiSourceName`, and this
///   build reads them back into the feature they always named.
/// - written by a build between the removal and this one: carries neither, and
///   an Optional field that is absent is nil — the switch is off, which is the
///   default anyway.
/// - written by this build: carries them again, and a build from the middle
///   period drops keys it does not know, so it still decodes.
///
/// `ModelSettingsMigrationTests.aBlobFromBeforeTheNDIRemovalGetsItsSourceBack`
/// and `aBlobWrittenWhileNDIWasRetiredStillDecodes` hold the first two.
///
/// **A stored `ndiEnabled == true` is honoured rather than ignored**, and that
/// is the opposite of the call the removal made. The removal refused to migrate
/// it onto the SRT switch because a source NAME answers none of SRT's
/// questions, and an SRT output pointed nowhere would have come up on first
/// launch. Here nothing is being migrated: the key means what it has always
/// meant, the feature it names is back, and an operator who left NDI on gets
/// their source back after the update — the same promise the remote server and
/// the menu-bar item already make across a relaunch.
public struct NDISettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case enabled = "ndiEnabled"
        case sourceName = "ndiSourceName"
    }

    /// The viewer is sent out as an NDI source; nil/false — off, which is the
    /// default. Optional, like every added field, so settings written by an
    /// older build still decode.
    public var enabled: Bool?
    /// Name the source is announced under; nil — `sourceNameEffective(_:)`.
    public var sourceName: String?

    public init() {}

    /// The name NDI announces. NDI presents a source to receivers as
    /// "MACHINE (name)" and supplies the machine half itself, so this carries
    /// the project and the camera and nothing else — putting the host in here
    /// too would print it twice in every source list on the shoot.
    ///
    /// **A function on this group rather than a property on `CaptureSettings`,
    /// which is where it used to live.** It was the only thing on the record
    /// that reached ACROSS two groups, and the grouping wave that followed left
    /// every other effective value sitting on the group that owns it. Taking
    /// the naming settings as an argument keeps that: this is pure in
    /// (ndi, naming) and can be reasoned about — and tested — without a record.
    public func sourceNameEffective(_ naming: NamingSettings) -> String {
        let chosen = sourceName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chosen.isEmpty { return chosen }
        let parts = [naming.projectName, naming.cameraLabel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "TakeShot" : parts.joined(separator: " ")
    }
}
