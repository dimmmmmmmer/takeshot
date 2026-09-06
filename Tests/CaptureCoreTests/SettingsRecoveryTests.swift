import Foundation
import Testing

@testable import CaptureCore

/// **A stored configuration that will not decode is set aside, not destroyed.**
///
/// It used to fall through to defaults, and the very next save — which is the
/// next thing that happens, since the app writes settings on any change — wrote
/// those defaults over it. A shoot's whole setup gone, with nothing to put back
/// and nothing said.
struct SettingsRecoveryTests {
    /// A defaults suite of its own, removed — the domain AND the plist
    /// cfprefsd leaves behind — when the test is done. It used to be
    /// `?? .standard`, which on a machine that refused the suite would have
    /// planted the damage in the operator's real settings.
    private func withScratch(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "takeshot.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            // cfprefsd writes lazily: without this the plist can land AFTER
            // the removeItem below and outlive the test anyway.
            defaults.synchronize()
            UserDefaults.standard.removeSuite(named: suite)
            try? FileManager.default.removeItem(
                at: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        try body(defaults)
    }

    @Test func adamagedBlobIsKeptAndReportedOnce() throws {
        try withScratch { defaults in
            let damaged = Data("{ this is not settings".utf8)
            defaults.set(damaged, forKey: CaptureSettings.defaultsKey)

            let first = CaptureSettings.load(from: defaults)
            #expect(first.unreadable == damaged,
                    "the launch that found the damage did not report it")
            #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == damaged,
                    "the operator's only copy was not kept")

            // Whatever the app writes next must not reach the kept copy.
            first.settings.save(to: defaults)
            #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == damaged,
                    "a save overwrote the kept copy")

            // A second launch is silent: the damage is known and saying it again
            // every morning is noise.
            let second = CaptureSettings.load(from: defaults)
            #expect(second.unreadable == nil,
                    "the same damage was reported at a second launch")
        }
    }

    /// A LATER damage is a new incident: kept, said, and the copy it displaces
    /// survives beside it. The stash used to be write-once for the life of
    /// the install — after one incident, even a year-old recovered one, every
    /// later corruption was silently discarded and then saved over.
    @Test func aLaterDamageIsKeptAndSaidWithoutLosingTheEarlierCopy() throws {
        try withScratch { defaults in
            let original = Data("{ the operator's real settings".utf8)
            defaults.set(original, forKey: CaptureSettings.defaultsKey)
            _ = CaptureSettings.load(from: defaults)

            let later = Data("{ damaged again, a year on".utf8)
            defaults.set(later, forKey: CaptureSettings.defaultsKey)
            let again = CaptureSettings.load(from: defaults)
            #expect(again.unreadable == later,
                    "the second corruption went unmentioned")
            #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == later,
                    "the newest damage is the one to keep")
            #expect(defaults.data(forKey: CaptureSettings.previousUnreadableKey)
                    == original, "the earlier copy was thrown away")
        }
    }

    /// A record a NEWER build wrote keeps its version stamp through a launch
    /// of this one, so the newer build does not run its re-readings twice.
    @Test func aBlobFromANewerBuildKeepsItsVersionStamp() throws {
        try withScratch { defaults in
            defaults.set(Data(#"{"schemaVersion": 99}"#.utf8),
                         forKey: CaptureSettings.defaultsKey)
            let load = CaptureSettings.load(from: defaults)
            #expect(load.settings.schemaVersion == 99,
                    "stamped down to \(load.settings.schemaVersion ?? -1)")
            load.settings.save(to: defaults)
            let saved = try #require(defaults.data(forKey: CaptureSettings.defaultsKey))
            let json = try #require(JSONSerialization.jsonObject(with: saved)
                                        as? [String: Any])
            #expect(json["schemaVersion"] as? Int == 99)
        }
    }

    /// Nothing stored at all is not damage — it is a first launch.
    @Test func afreshInstallKeepsNothingAndReportsNothing() throws {
        try withScratch { defaults in
            let load = CaptureSettings.load(from: defaults)
            #expect(load.unreadable == nil)
            #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == nil)
        }
    }

    /// And a blob that DOES decode is left entirely alone.
    @Test func agoodBlobIsNotTouched() throws {
        try withScratch { defaults in
            var settings = CaptureSettings()
            settings.capture.destinationPath = "/tmp/takeshot-recovery"
            settings.save(to: defaults)

            let load = CaptureSettings.load(from: defaults)
            #expect(load.unreadable == nil)
            #expect(load.settings.capture.destinationPath == "/tmp/takeshot-recovery")
            #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == nil)
        }
    }
}
