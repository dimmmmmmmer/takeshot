import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// What happens to a settings blob written by an older build.
///
/// Every added field is Optional so it decodes as nil, and the synthesized
/// decoder drops keys it does not know so a REMOVED one decodes harmlessly.
/// Neither is enough on its own for a feature retired INTO something else, or
/// for an enum that lost a case: those need the migration chain, and a
/// migration nobody exercises is a migration that has never run.
///
/// The blobs below are hand-written JSON on purpose. Encoding a current
/// `CaptureSettings` and editing it would only ever produce fields this build
/// still has, which is precisely what is under test.
@Suite struct ModelSettingsMigrationTests {
    /// The defaults key `CaptureSettings` persists under.
    private static let key = "TakeShot.CaptureSettings"

    /// A blob as an older build wrote it: every field the decoder REQUIRES
    /// (the non-Optional ones — a synthesized decoder does not fall back to a
    /// property's default), plus whatever the case under test is about.
    private func store(_ extra: String,
                       schemaVersion: Int? = 1) -> UserDefaults {
        let version = schemaVersion.map { ",\"schemaVersion\":\($0)" } ?? ""
        let json = """
            {"codec":"ProRes 422","namingTemplate":"{prefix}_{cam}C{clip}",
             "destinationPath":"/tmp/shoot","detectionMode":"vanc",
             "startDebounceFrames":3,"stopDebounceFrames":7,
             "projectName":"Nightfall","cameraLabel":"B"\(extra)\(version)}
            """
        let defaults = InMemoryDefaults()
        defaults.set(Data(json.utf8), forKey: Self.key)
        return defaults
    }

    // MARK: - input levels: two Limited options became one

    /// The operator who had asked for the excursions to survive keeps exactly
    /// the reading they asked for — under the name the one Limited now has.
    @Test func theExcursionModeMigratesOntoTheSingleLimited() {
        let settings = CaptureSettings.loaded(
            from: store(",\"videoLevels\":\"limited_excursions\""))
        #expect(settings.capture.videoLevels == InputLevels.limited.rawValue)
        #expect(InputLevels.resolved(settings.capture.videoLevels) == .limited)
    }

    /// And the operator who had the plain spelling is left alone: the value is
    /// already the surviving one. What it MEANS changed — that is the owner's
    /// decision, not something a migration hides.
    @Test func thePlainLimitedSpellingIsUntouched() {
        let settings = CaptureSettings.loaded(
            from: store(",\"videoLevels\":\"limited\""))
        #expect(settings.capture.videoLevels == "limited")
        #expect(InputLevels.resolved(settings.capture.videoLevels) == .limited)
    }

    /// Auto and Full are not touched by any of this.
    @Test func theOtherTwoOptionsSurviveTheMigration() {
        #expect(CaptureSettings.loaded(from: store("")).capture.videoLevels == nil)
        #expect(CaptureSettings.loaded(from: store(",\"videoLevels\":\"full\""))
            .capture.videoLevels == "full")
    }

    // MARK: - the retired verified backup

    /// The verified-backup folder is gone as a setting; the disk the operator
    /// had chosen becomes an offload destination, which is the feature that
    /// superseded it.
    @Test func theRetiredBackupFolderBecomesAnOffloadDestination() {
        let settings = CaptureSettings.loaded(
            from: store(",\"backupPath\":\"/Volumes/OLD\""))
        #expect(settings.offload.destinationPaths == ["/Volumes/OLD"])
    }

    /// An operator who already set up a destination list keeps it: their own
    /// rig is never second-guessed by a migration.
    @Test func anExistingDestinationListIsNotOverwritten() {
        let settings = CaptureSettings.loaded(from: store("""
            ,"backupPath":"/Volumes/OLD",
             "offloadDestinationPaths":["/Volumes/SSD1"]
            """))
        #expect(settings.offload.destinationPaths == ["/Volumes/SSD1"])
    }

    /// …and the migration runs ONCE. A blob already at the current version is
    /// not re-read for a field this build no longer writes.
    @Test func theMigrationDoesNotRunOnAnAlreadyMigratedBlob() {
        let settings = CaptureSettings.loaded(from: store(
            ",\"backupPath\":\"/Volumes/OLD\",\"videoLevels\":\"limited_excursions\"",
            schemaVersion: CaptureSettings.currentSchemaVersion))
        #expect(settings.offload.destinationPaths == nil)
        #expect(settings.capture.videoLevels == "limited_excursions",
                "a blob at the current version was migrated again")
    }

    // MARK: - version 3: the legend's corner, the key's softness

    /// The exposure legend moved from four corners to four edges (owner items
    /// 39/40). Which SIDE the corner was on says nothing about a strip that now
    /// spans the whole edge, so only top vs bottom carries over — and bottom is
    /// the new default, which is stored as nil.
    @Test func aStoredLegendCornerBecomesAnEdge() {
        #expect(CaptureSettings.loaded(from: store(",\"legendCorner\":\"topLeading\""))
            .assist.legendPlacement == "top")
        #expect(CaptureSettings.loaded(from: store(",\"legendCorner\":\"topTrailing\""))
            .assist.legendPlacement == "top")
        #expect(CaptureSettings.loaded(
            from: store(",\"legendCorner\":\"bottomLeading\"")).assist.legendPlacement == nil)
        #expect(CaptureSettings.loaded(
            from: store(",\"legendCorner\":\"bottomTrailing\"")).assist.legendPlacement == nil)
        // nothing stored stays nothing stored — the default, bottom centre
        #expect(CaptureSettings.loaded(from: store("")).assist.legendPlacement == nil)
    }

    /// The chroma key's feather used to be an absolute chroma width hung
    /// OUTSIDE the tolerance and is now a fraction of it, straddling it (owner
    /// item 35). The value still decodes and would mean something else, so it
    /// is converted on the width the operator actually dialled in: the old ramp
    /// was `softness` wide, the new one is `2 · tolerance · softness`.
    @Test func theChromaSoftnessBecomesAFractionOfTheTolerance() {
        let settings = CaptureSettings.loaded(from: store("""
            ,"chromaKeyTolerance":0.25,"chromaKeySoftness":0.1
            """))
        #expect(settings.chromaKey.softness == 0.2,
                "a 0.1-wide feather at tolerance 0.25 is 0.2 of it either side")
        #expect(settings.chromaKey.tolerance == 0.25, "the tolerance moved")

        // a stored feather with no stored tolerance is read against the default
        let onDefault = CaptureSettings.loaded(
            from: store(",\"chromaKeySoftness\":0.1"))
        #expect(onDefault.chromaKey.softness == 0.25)

        // the widest old feather cannot come back wider than the new scale goes
        let widest = CaptureSettings.loaded(from: store("""
            ,"chromaKeyTolerance":0.05,"chromaKeySoftness":0.4
            """))
        #expect(widest.chromaKey.softness == 1)

        // a hard cut stays a hard cut, and nothing stored stays nothing stored
        #expect(CaptureSettings.loaded(from: store(",\"chromaKeySoftness\":0"))
            .chromaKey.softness == 0)
        #expect(CaptureSettings.loaded(from: store("")).chromaKey.softness == nil)
    }

    /// …and a blob this build already wrote is left alone: converting a
    /// fraction as if it were a width would halve the operator's feather on
    /// every launch.
    @Test func anAlreadyRelativeSoftnessIsNotConvertedAgain() {
        let settings = CaptureSettings.loaded(
            from: store(",\"chromaKeySoftness\":0.5",
                        schemaVersion: CaptureSettings.currentSchemaVersion))
        #expect(settings.chromaKey.softness == 0.5)
    }

    // MARK: - the removed field decodes harmlessly

    /// The whole point of removing a field rather than deprecating it: an old
    /// blob still decodes, everything else in it still arrives, and nothing
    /// this build writes mentions the field again.
    @Test func anOldBlobWithTheRemovedFieldStillDecodes() throws {
        let settings = CaptureSettings.loaded(from: store("""
            ,"backupPath":"/Volumes/OLD","videoLevels":"limited_excursions"
            """))
        #expect(settings.capture.destinationPath == "/tmp/shoot")
        #expect(settings.naming.projectName == "Nightfall")
        #expect(settings.naming.cameraLabel == "B")
        #expect(settings.capture.startDebounceFrames == 3)
        #expect(settings.capture.stopDebounceFrames == 7)
        #expect(settings.schemaVersion == CaptureSettings.currentSchemaVersion)

        // and what this build writes back carries no trace of the retired field
        let round = try #require(String(
            data: try JSONEncoder().encode(settings), encoding: .utf8))
        #expect(!round.contains("backupPath"))
        #expect(!round.contains("limited_excursions"))
    }

    /// A blob carrying `captureBitDepth` still decodes, and everything else in
    /// it survives.
    ///
    /// That key was the bit-depth picker, and the picker is gone: depth follows
    /// the signal now. It is the one key ever removed from this record, and the
    /// failure it could have caused is the worst one this file exists for — a
    /// decode that throws hands `loaded(from:)` a fresh default object, so the
    /// operator's destination folder, naming template, calibrated thresholds and
    /// taught REC references are silently replaced by defaults, on a shooting
    /// day, with no error anywhere.
    ///
    /// Nothing carries the stored depth across, deliberately: there is no
    /// setting left for it to mean anything to, and an operator who had picked
    /// 8-bit to save bandwidth is moved onto what their camera is actually
    /// sending. So this checks the two halves that ARE contracts — the blob
    /// decodes, and this build writes it back without the key.
    @Test func anOldBlobWithARetiredBitDepthStillDecodes() throws {
        let settings = CaptureSettings.loaded(from: store("""
            ,"captureBitDepth":"12","tenBitCapture":false,"ltcChannel":3
            """))
        #expect(settings.capture.destinationPath == "/tmp/shoot")
        #expect(settings.naming.projectName == "Nightfall")
        #expect(settings.capture.ltcChannel == 3)
        #expect(settings.capture.startDebounceFrames == 3)
        #expect(settings.schemaVersion == CaptureSettings.currentSchemaVersion)

        let round: String = try #require(String(
            data: try JSONEncoder().encode(settings), encoding: .utf8))
        #expect(!round.contains("captureBitDepth"),
                "the retired key was written back")
    }

    /// A blob written before `schemaVersion` existed is version 0: it still has
    /// to reach the current version, running every step on the way.
    @Test func aVersionlessBlobRunsTheWholeChain() {
        let settings = CaptureSettings.loaded(from: store(
            ",\"backupPath\":\"/Volumes/OLD\",\"videoLevels\":\"limited_excursions\"",
            schemaVersion: nil))
        #expect(settings.capture.videoLevels == "limited")
        #expect(settings.offload.destinationPaths == ["/Volumes/OLD"])
        #expect(settings.schemaVersion == CaptureSettings.currentSchemaVersion)
    }

    /// A blob that is not decodable JSON at all falls back to the defaults
    /// rather than taking the launch with it — the retired-field decode is
    /// best-effort for the same reason.
    @Test func anUnreadableBlobFallsBackToTheDefaults() {
        let defaults = InMemoryDefaults()
        defaults.set(Data("not json".utf8), forKey: Self.key)
        let settings = CaptureSettings.loaded(from: defaults)
        #expect(settings.capture.videoLevels == nil)
        #expect(settings.offload.destinationPaths == nil)
    }
}
