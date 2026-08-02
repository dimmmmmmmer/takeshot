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
        #expect(settings.videoLevels == InputLevels.limited.rawValue)
        #expect(InputLevels.resolved(settings.videoLevels) == .limited)
    }

    /// And the operator who had the plain spelling is left alone: the value is
    /// already the surviving one. What it MEANS changed — that is the owner's
    /// decision, not something a migration hides.
    @Test func thePlainLimitedSpellingIsUntouched() {
        let settings = CaptureSettings.loaded(
            from: store(",\"videoLevels\":\"limited\""))
        #expect(settings.videoLevels == "limited")
        #expect(InputLevels.resolved(settings.videoLevels) == .limited)
    }

    /// Auto and Full are not touched by any of this.
    @Test func theOtherTwoOptionsSurviveTheMigration() {
        #expect(CaptureSettings.loaded(from: store("")).videoLevels == nil)
        #expect(CaptureSettings.loaded(from: store(",\"videoLevels\":\"full\""))
            .videoLevels == "full")
    }

    // MARK: - the retired verified backup

    /// The verified-backup folder is gone as a setting; the disk the operator
    /// had chosen becomes an offload destination, which is the feature that
    /// superseded it.
    @Test func theRetiredBackupFolderBecomesAnOffloadDestination() {
        let settings = CaptureSettings.loaded(
            from: store(",\"backupPath\":\"/Volumes/OLD\""))
        #expect(settings.offloadDestinationPaths == ["/Volumes/OLD"])
    }

    /// An operator who already set up a destination list keeps it: their own
    /// rig is never second-guessed by a migration.
    @Test func anExistingDestinationListIsNotOverwritten() {
        let settings = CaptureSettings.loaded(from: store("""
            ,"backupPath":"/Volumes/OLD",
             "offloadDestinationPaths":["/Volumes/SSD1"]
            """))
        #expect(settings.offloadDestinationPaths == ["/Volumes/SSD1"])
    }

    /// …and the migration runs ONCE. A blob already at the current version is
    /// not re-read for a field this build no longer writes.
    @Test func theMigrationDoesNotRunOnAnAlreadyMigratedBlob() {
        let settings = CaptureSettings.loaded(from: store(
            ",\"backupPath\":\"/Volumes/OLD\",\"videoLevels\":\"limited_excursions\"",
            schemaVersion: CaptureSettings.currentSchemaVersion))
        #expect(settings.offloadDestinationPaths == nil)
        #expect(settings.videoLevels == "limited_excursions",
                "a blob at the current version was migrated again")
    }

    // MARK: - the removed field decodes harmlessly

    /// The whole point of removing a field rather than deprecating it: an old
    /// blob still decodes, everything else in it still arrives, and nothing
    /// this build writes mentions the field again.
    @Test func anOldBlobWithTheRemovedFieldStillDecodes() throws {
        let settings = CaptureSettings.loaded(from: store("""
            ,"backupPath":"/Volumes/OLD","videoLevels":"limited_excursions"
            """))
        #expect(settings.destinationPath == "/tmp/shoot")
        #expect(settings.projectName == "Nightfall")
        #expect(settings.cameraLabel == "B")
        #expect(settings.startDebounceFrames == 3)
        #expect(settings.stopDebounceFrames == 7)
        #expect(settings.schemaVersion == CaptureSettings.currentSchemaVersion)

        // and what this build writes back carries no trace of the retired field
        let round = try #require(String(
            data: try JSONEncoder().encode(settings), encoding: .utf8))
        #expect(!round.contains("backupPath"))
        #expect(!round.contains("limited_excursions"))
    }

    /// A blob written before `schemaVersion` existed is version 0: it still has
    /// to reach the current version, running every step on the way.
    @Test func aVersionlessBlobRunsTheWholeChain() {
        let settings = CaptureSettings.loaded(from: store(
            ",\"backupPath\":\"/Volumes/OLD\",\"videoLevels\":\"limited_excursions\"",
            schemaVersion: nil))
        #expect(settings.videoLevels == "limited")
        #expect(settings.offloadDestinationPaths == ["/Volumes/OLD"])
        #expect(settings.schemaVersion == CaptureSettings.currentSchemaVersion)
    }

    /// A blob that is not decodable JSON at all falls back to the defaults
    /// rather than taking the launch with it — the retired-field decode is
    /// best-effort for the same reason.
    @Test func anUnreadableBlobFallsBackToTheDefaults() {
        let defaults = InMemoryDefaults()
        defaults.set(Data("not json".utf8), forKey: Self.key)
        let settings = CaptureSettings.loaded(from: defaults)
        #expect(settings.videoLevels == nil)
        #expect(settings.offloadDestinationPaths == nil)
    }
}
