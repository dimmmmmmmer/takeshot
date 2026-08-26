import CaptureCore
import Foundation
import Testing

/// Every settings group maps its properties onto the persisted keys by ONE
/// mechanical rule, checked here field by field.
///
/// `ModelSettingsFormatTests` pins the key SET and pins that every value
/// survives a round trip. Neither can see the last way left to lose data
/// silently: two fields of the same type whose `CodingKeys` are transposed. The
/// key set is unchanged and the round trip is exact — and the operator's spill
/// suppression is now their tolerance. No round-trip test can catch that, ever,
/// because the trip is symmetric.
///
/// Only the groups that STRIP a prefix can have that bug at all. The rest name
/// their properties exactly as the key is spelled, so the compiler's synthesis
/// IS the mapping and there is nothing to hand-write wrong. This checks the
/// ones with a hand-written `CodingKeys`, by reflecting the property labels,
/// encoding the group, and requiring the two to line up.
///
/// The rule, stated once: a persisted key is the group's prefix followed by the
/// property label with its first letter capitalised — or the label unchanged,
/// for a key that predates the group owning it (`offerMountedCards`). Compared
/// case-insensitively, because `remotePIN` is spelled the way a PIN is spelled;
/// the exact casing is what `ModelSettingsFormatTests` pins.
@Suite struct ModelSettingsGroupNamingTests {
    /// A group filled from the pinned blob. Every key of the format is in
    /// there, so a group decoded from it comes out with every field set and
    /// encodes every key it owns — which a default-constructed group would not,
    /// all of its fields being nil.
    private func filled<T: Codable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: SettingsFormatFixture.populatedData)
    }

    private func keys<T: Codable>(_ value: T) throws -> [String] {
        SettingsFormatFixture.object(from: try JSONEncoder().encode(value))
            .keys.sorted()
    }

    /// Where a group's keys and its property names fail to derive from each
    /// other. Returns the complaints rather than asserting, so one test can
    /// walk every group and a failure names which.
    private func mismatches<T: Codable>(_ type: T.Type, _ prefix: String) throws -> [String] {
        let value = try filled(type)
        let written = Set(try keys(value).map { $0.lowercased() })
        var explained: Set<String> = []
        var bad: [String] = []
        for label in Mirror(reflecting: value).children.compactMap(\.label) {
            // String(_:) around dropFirst() is not decoration: it returns a
            // DropFirstSequence, and only the newer compiler infers its way to
            // a String through the concatenation. The runner's Swift does not,
            // and the test target is the one thing the two-SDK check here
            // cannot cover (docs/ARCHITECTURE.md) — so CI found this, twice.
            let prefixed = (prefix + label.prefix(1).uppercased()
                + String(label.dropFirst())).lowercased()
            if written.contains(prefixed) {
                explained.insert(prefixed)
            } else if written.contains(label.lowercased()) {
                explained.insert(label.lowercased())
            } else {
                bad.append("\(prefix): property '\(label)' writes no key the rule predicts")
            }
        }
        for key in written.subtracting(explained).sorted() {
            bad.append("\(prefix): key '\(key)' derives from no property of this group")
        }
        return bad
    }

    /// Every prefixed group, field by field. A transposed pair fails here: the
    /// key such a property would write is the OTHER one's, and no label in the
    /// group derives it.
    @Test func everyGroupKeyIsItsOwnPropertyNameUnderTheGroupPrefix() throws {
        var bad: [String] = []
        bad += try mismatches(LUTSettings.self, "lut")
        bad += try mismatches(R3DSettings.self, "r3d")
        bad += try mismatches(ChromaKeySettings.self, "chromaKey")
        bad += try mismatches(VisualRecSettings.self, "visualRec")
        bad += try mismatches(RemoteSettings.self, "remote")
        bad += try mismatches(NDISettings.self, "ndi")
        bad += try mismatches(SRTSettings.self, "srt")
        bad += try mismatches(DailiesSettings.self, "dailies")
        bad += try mismatches(OffloadSettings.self, "offload")
        #expect(bad == [String]())
    }

    /// The unprefixed groups keep their persisted names verbatim, so the same
    /// check is just "label == key" — and it is worth making, because a rename
    /// inside one of them looks like ordinary tidying and is a data loss.
    @Test func theUnprefixedGroupsNameTheirFieldsExactlyAsTheyArePersisted() throws {
        var bad: [String] = []
        bad += try mismatches(CaptureSignalSettings.self, "")
        bad += try mismatches(NamingSettings.self, "")
        bad += try mismatches(AudioSettings.self, "")
        bad += try mismatches(ThemeSettings.self, "")
        bad += try mismatches(AssistSettings.self, "")
        bad += try mismatches(ReviewSettings.self, "")
        #expect(bad == [String]())
    }

    /// And the fifteen groups together account for the whole format, exactly
    /// once each.
    ///
    /// This is what fails if a group is declared but never wired into
    /// `CaptureSettings`'s `encode(to:)`/`init(from:)` — the group's keys simply
    /// stop being written, which is a whole domain of settings lost at once and
    /// the failure mode that hand-written delegation can actually have.
    @Test func theGroupsAccountForEveryPersistedKeyExactlyOnce() throws {
        var claimed: [String] = []
        claimed += try keys(filled(CaptureSignalSettings.self))
        claimed += try keys(filled(NamingSettings.self))
        claimed += try keys(filled(AudioSettings.self))
        claimed += try keys(filled(ThemeSettings.self))
        claimed += try keys(filled(AssistSettings.self))
        claimed += try keys(filled(ReviewSettings.self))
        claimed += try keys(filled(LUTSettings.self))
        claimed += try keys(filled(R3DSettings.self))
        claimed += try keys(filled(ChromaKeySettings.self))
        claimed += try keys(filled(VisualRecSettings.self))
        claimed += try keys(filled(RemoteSettings.self))
        claimed += try keys(filled(NDISettings.self))
        claimed += try keys(filled(SRTSettings.self))
        claimed += try keys(filled(DailiesSettings.self))
        claimed += try keys(filled(OffloadSettings.self))
        #expect(Set(claimed).count == claimed.count,
                "two settings groups claim the same persisted key")
        // Plus schemaVersion, which belongs to the record rather than to any
        // domain in it. Together that is the whole pinned format.
        #expect((claimed + ["schemaVersion"]).sorted()
            == SettingsFormatFixture.allKeys)
    }
}
