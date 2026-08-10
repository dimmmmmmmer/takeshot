import Foundation

/// App settings (persisted in UserDefaults as JSON).
///
/// Two things at once, and the split between them is the whole design here.
///
/// **It is the RECORD.** This type IS the on-disk format: one JSON blob under
/// one defaults key, and there is no error path for getting the shape wrong. A
/// key that moves does not fail — it stops decoding, `loaded(from:)` answers
/// the throw with a fresh default object, and the operator's destination
/// folder, naming template, calibrated assist thresholds and taught REC
/// references are silently replaced by defaults on a shooting day. So the
/// encoded shape is pinned as data by `ModelSettingsFormatTests`, and the
/// persisted spelling of every field is a contract rather than a style choice.
///
/// **It is the app's configuration SURFACE**, read at several hundred call
/// sites. That is the job that wanted grouping: it grew to 84 flat fields, and
/// half of them carried a hand-maintained prefix (`chromaKeyPlateOffsetX`)
/// standing in for the namespace they could not have.
///
/// The two jobs are reconciled by keeping the wire format flat while the TYPE
/// is grouped. The groups below each own a domain and each carry their own
/// synthesized `Codable`; the `Codable` on this type delegates to them into a
/// SINGLE keyed container, so every key still lands at the top level exactly
/// where it always did. Nothing here hand-writes a per-field encode or decode —
/// the field-to-key mapping is still the compiler's, which is what makes the
/// 88 keys unforgeable.
///
/// Flatness is load-bearing for a second consumer as well as for the stored
/// blob: `DiagnosticsRedaction` walks this encoding as a flat map and drops
/// secrets by matching the top-level key NAME, which is how `remotePIN` stays
/// out of a bundle that gets emailed to someone. Nest it and the filter stops
/// seeing it. `ModelSettingsFormatTests` checks that too.
///
/// **Adding a setting**: put it in the group it belongs to, make it Optional
/// (a synthesized decoder requires every non-Optional key, so a required field
/// added today makes every blob written before today undecodable), and add its
/// key to the pinned list in `SettingsFormatFixture`. Adding a whole GROUP
/// means adding it to `init(from:)` and `encode(to:)` below — a group left out
/// of either takes all of its keys with it, which is a loud failure in the
/// format tests rather than a quiet one on somebody's set.
public struct CaptureSettings: Codable, Equatable, Sendable {
    /// Getting the signal off the board and into a file.
    public var capture = CaptureSignalSettings()
    /// What the file is called.
    public var naming = NamingSettings()
    /// The monitor speaker, the recorded channels, the devices.
    public var audio = AudioSettings()
    /// The app's own theme, backdrops and accent.
    public var theme = ThemeSettings()
    /// The aids drawn over the picture.
    public var assist = AssistSettings()
    /// Compare mode and the marker colour convention.
    public var review = ReviewSettings()
    /// The preview/record LUT.
    public var lut = LUTSettings()
    /// RED .r3d playback.
    public var r3d = R3DSettings()
    /// The chroma keyer's dial-in.
    public var chromaKey = ChromaKeySettings()
    /// The taught REC indicator.
    public var visualRec = VisualRecSettings()
    /// The browser remote.
    public var remote = RemoteSettings()
    /// The SRT output.
    public var srt = SRTSettings()
    /// The dailies burn-in set.
    public var dailies = DailiesSettings()
    /// The DIT offload's destinations.
    public var offload = OffloadSettings()

    /// Version of the decoded blob. Optional so that saves written before this
    /// field existed decode as nil and are treated as version 0.
    ///
    /// Not in a group: it is about the record itself rather than about any
    /// domain in it.
    public var schemaVersion: Int?

    public init() {}

    // MARK: - the flat wire format

    /// The only key this type owns directly.
    private enum RecordKeys: String, CodingKey {
        case schemaVersion
    }

    /// Each group decodes from the SAME top-level container, so a grouped type
    /// reads a flat blob — including every blob written before the grouping
    /// existed, which is the point.
    public init(from decoder: Decoder) throws {
        capture = try CaptureSignalSettings(from: decoder)
        naming = try NamingSettings(from: decoder)
        audio = try AudioSettings(from: decoder)
        theme = try ThemeSettings(from: decoder)
        assist = try AssistSettings(from: decoder)
        review = try ReviewSettings(from: decoder)
        lut = try LUTSettings(from: decoder)
        r3d = try R3DSettings(from: decoder)
        chromaKey = try ChromaKeySettings(from: decoder)
        visualRec = try VisualRecSettings(from: decoder)
        remote = try RemoteSettings(from: decoder)
        srt = try SRTSettings(from: decoder)
        dailies = try DailiesSettings(from: decoder)
        offload = try OffloadSettings(from: decoder)
        let container = try decoder.container(keyedBy: RecordKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    /// And each group encodes back into the same one. Asking an encoder for a
    /// keyed container twice at the same coding path hands back the container
    /// it already made, so fourteen groups produce one flat object.
    public func encode(to encoder: Encoder) throws {
        try capture.encode(to: encoder)
        try naming.encode(to: encoder)
        try audio.encode(to: encoder)
        try theme.encode(to: encoder)
        try assist.encode(to: encoder)
        try review.encode(to: encoder)
        try lut.encode(to: encoder)
        try r3d.encode(to: encoder)
        try chromaKey.encode(to: encoder)
        try visualRec.encode(to: encoder)
        try remote.encode(to: encoder)
        try srt.encode(to: encoder)
        try dailies.encode(to: encoder)
        try offload.encode(to: encoder)
        var container = encoder.container(keyedBy: RecordKeys.self)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
    }

    // MARK: - persistence

    static let defaultsKey = "TakeShot.CaptureSettings"

    public static func loaded(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        settings = migrate(settings, retired: RetiredSettings(from: data))
        settings.schemaVersion = currentSchemaVersion
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
