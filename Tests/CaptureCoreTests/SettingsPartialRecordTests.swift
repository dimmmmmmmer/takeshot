import Foundation
import Testing

@testable import CaptureCore

/// **A partial settings record is a record, not corruption.**
///
/// Every group decodes from one flat object, and fourteen of the fifteen are
/// optionals through and through — "nil means the default" is the documented
/// contract. Two were not: `CaptureSignalSettings` and `NamingSettings` had
/// eight non-optional fields with defaults, and a synthesized `Codable` treats
/// a field with a default as REQUIRED. So a blob missing `codec` — a hand-edited
/// record, a partial one, a future build that renames a key — failed to decode
/// as a whole, and `load(from:)` answered with a fresh object: the operator's
/// destination folder, naming template, thresholds and taught references reset
/// to defaults, on the first launch of the day. Found by seeding a one-key blob
/// and watching it land under `captureSettingsUnreadable`.
@Suite struct SettingsPartialRecordTests {
    @Test func anEmptyObjectDecodesToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(CaptureSettings.self,
                                               from: Data("{}".utf8))
        #expect(decoded.capture.codec == CaptureSettings().capture.codec)
        #expect(decoded.naming.namingTemplate
            == CaptureSettings().naming.namingTemplate)
        #expect(decoded.capture.destinationPath
            == CaptureSettings().capture.destinationPath)
    }

    /// `codec` and `detectionMode` are the only typed enums on the wire. A
    /// raw value this build does not know — a rollback after a newer build
    /// added a case, a hand edit — is that ONE field at its default; the
    /// synthesized decoding threw and the whole record went unreadable.
    @Test func anUnknownEnumValueIsThatOneFieldAtItsDefault() throws {
        let blob = #"{"detectionMode": "hologram", "codec": "ProRes 9000", "#
            + #""destinationPath": "/Volumes/SHOOT"}"#
        let decoded = try JSONDecoder().decode(CaptureSettings.self,
                                               from: Data(blob.utf8))
        #expect(decoded.capture.destinationPath == "/Volumes/SHOOT",
                "one unknown value cost the record")
        #expect(decoded.capture.detectionMode == CaptureSettings().capture.detectionMode)
        #expect(decoded.capture.codec == CaptureSettings().capture.codec)
    }

    @Test func aOneKeyBlobKeepsThatKeyAndDefaultsTheRest() throws {
        let decoded = try JSONDecoder().decode(
            CaptureSettings.self, from: Data(#"{"remoteEnabled": true}"#.utf8))
        #expect(decoded.remote.enabled == true, "the one key it carried was lost")
        #expect(decoded.capture.codec == .proRes422)
    }

    /// The record round-trips through the tolerant path unchanged: what the
    /// encoder writes, the decoder reads back equal — the contract every
    /// existing operator's blob relies on.
    @Test func aFullRecordRoundTrips() throws {
        var settings = CaptureSettings()
        settings.capture.codec = .proResHQ
        settings.naming.projectName = "Проба"
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(CaptureSettings.self, from: data)
        #expect(back == settings)
    }
}
