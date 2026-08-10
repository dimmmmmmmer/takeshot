import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The persisted shape of `CaptureSettings`, held still.
///
/// `ModelSettingsMigrationTests` covers what happens to a blob written by an
/// OLDER build. This covers the other half, which nothing pinned before: what
/// this build writes, and that it is exactly what the last one wrote. There is
/// no error path for getting that wrong — a settings blob whose shape moved
/// simply fails to decode and the operator's whole configuration is replaced by
/// defaults, silently, the first time they launch the update.
///
/// Every assertion here is phrased in JSON, never in `settings.someField`. That
/// is deliberate: this suite is the fixture a refactor of the type is read
/// against, so it must not be something a refactor of the type can edit. If a
/// test in here has to change, the format changed.
///
/// See `SettingsFormatFixture` for the pinned key list and the blob.
@Suite struct ModelSettingsFormatTests {
    private func decodeFixture() throws -> CaptureSettings {
        try JSONDecoder().decode(CaptureSettings.self,
                                 from: SettingsFormatFixture.populatedData)
    }

    private func reencodeFixture() throws -> [String: Any] {
        SettingsFormatFixture.object(
            from: try JSONEncoder().encode(try decodeFixture()))
    }

    // MARK: - the key set

    /// The fixture has to exercise the WHOLE format, or the round-trip tests
    /// below are only pinning the part of it somebody remembered to write down.
    @Test func theFixtureCoversEveryKeyTheFormatHas() {
        let stored = SettingsFormatFixture.object(
            from: SettingsFormatFixture.populatedData)
        #expect(stored.keys.sorted() == SettingsFormatFixture.allKeys)
    }

    /// What this build writes, key for key. The list it is compared against is
    /// a literal, so a field that is added, removed or renamed shows up here as
    /// a decision somebody has to make rather than as a shipped data loss.
    @Test func encodingReproducesTheStoredKeySetExactly() throws {
        #expect(try reencodeFixture().keys.sorted()
            == SettingsFormatFixture.allKeys)
    }

    /// A default install writes the eight non-Optional fields and nothing else:
    /// every other field is Optional, and a nil Optional is omitted rather than
    /// written as null.
    ///
    /// This is the test that fails if somebody adds a NON-Optional field. That
    /// is the change the whole "new settings fields must be Optional" rule
    /// exists to prevent — a synthesized decoder requires every non-Optional
    /// key, so one more of them makes every blob written before today throw,
    /// and `loaded(from:)` answers a throw with a fresh default settings object.
    @Test func aDefaultInstanceWritesOnlyTheRequiredKeys() throws {
        let object = SettingsFormatFixture.object(
            from: try JSONEncoder().encode(CaptureSettings()))
        #expect(object.keys.sorted() == SettingsFormatFixture.alwaysWrittenKeys)
    }

    // MARK: - the values

    /// Decode the blob, encode it again, and every one of the 88 values has to
    /// come back the same. The fixture gives each key a distinct value, so two
    /// fields that had quietly swapped keys would show up here as two changed
    /// lines rather than round-tripping past a key-set check.
    @Test func everyStoredValueSurvivesTheRoundTrip() throws {
        let before = SettingsFormatFixture.object(
            from: SettingsFormatFixture.populatedData)
        #expect(SettingsFormatFixture.lines(of: try reencodeFixture())
            == SettingsFormatFixture.lines(of: before))
    }

    /// The encoded object is FLAT — no key holds another object.
    ///
    /// A privacy contract, not a style one: `DiagnosticsRedaction` walks these
    /// keys and drops the ones whose NAME marks them secret, which is how
    /// `remotePIN` stays out of a bundle that gets emailed to someone. A key
    /// nested one level down is a key that filter no longer sees.
    @Test func theEncodedBlobIsFlat() throws {
        let nested = try reencodeFixture().filter { _, value in
            if value is NSDictionary { return true }
            if let array = value as? [Any] {
                return array.contains { $0 is NSDictionary || $0 is NSArray }
            }
            return false
        }
        #expect(nested.keys.sorted() == [String]())
    }

    // MARK: - the layer the app actually persists through

    /// `save` and `loaded` are what the app calls, and `loaded` runs the
    /// migration chain — so pinning `JSONEncoder` alone would pin a layer the
    /// operator never reaches. At the current schema version the chain is a
    /// no-op and the whole trip is the identity, which is the thing that has to
    /// stay true: relaunching the app must not change one stored value.
    @Test func aSaveAndLoadRoundTripThroughDefaultsIsTheIdentity() {
        let defaults = InMemoryDefaults()
        defaults.set(SettingsFormatFixture.populatedData,
                     forKey: SettingsFormatFixture.defaultsKey)
        CaptureSettings.loaded(from: defaults).save(to: defaults)
        let after = defaults.data(forKey: SettingsFormatFixture.defaultsKey) ?? Data()
        let before = SettingsFormatFixture.object(
            from: SettingsFormatFixture.populatedData)
        #expect(SettingsFormatFixture.lines(of: SettingsFormatFixture.object(from: after))
            == SettingsFormatFixture.lines(of: before))
    }

    /// And it is stored under the documented key. Change this string and every
    /// operator's settings are not migrated, not reset — orphaned, with the old
    /// blob still sitting in the plist under the old name.
    @Test func theBlobIsStoredUnderTheDocumentedDefaultsKey() {
        let defaults = InMemoryDefaults()
        CaptureSettings().save(to: defaults)
        #expect(defaults.data(forKey: SettingsFormatFixture.defaultsKey) != nil)
    }

    // MARK: - the second consumer of the shape

    /// The diagnostics bundle reads the same encoding, and its secret filter
    /// works on the top-level key names. Pinned here rather than only in the
    /// redaction suite because what makes it work is a property of the FORMAT:
    /// the PIN has to be reachable as a top-level key for the filter to drop it,
    /// and every other field has to be reachable for the bundle to report it.
    @Test func theDiagnosticsBundleSeesTheFlatKeysAndDropsThePIN() throws {
        let printed = DiagnosticsRedaction.settings(try decodeFixture())
        #expect(printed["remotePIN"] == nil)
        #expect(printed["remotePort"] == "9123")
        #expect(printed["monitorEnabled"] == "false")
        #expect(printed["offloadDestinationPaths"]
            == "/Volumes/BACKUP_A, /Volumes/BACKUP_B")
        // Everything the filter does NOT call a secret is reported, and the
        // list is derived from the filter rather than written out, so this
        // states the contract instead of pinning today's matches.
        //
        // Written when the filter matched raw substrings, and it found one:
        // `keepInMenuBar` lowercases to "kee-pin-menubar" and was dropped from
        // every bundle as collateral. The filter now matches a marker only
        // where it BEGINS a camel-case component, so the PIN still goes and
        // that setting is reported (see
        // ModelDiagnosticsTests.theRuleSeparatesAPinFromAKeepIn). This
        // expectation needed no change for that, which is the point of
        // deriving it.
        let expected = SettingsFormatFixture.allKeys
            .filter { !DiagnosticsRedaction.isSecretKey($0) }
        #expect(printed.keys.sorted() == expected)
    }
}
