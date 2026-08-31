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
    private func scratch() -> UserDefaults {
        let suite = "takeshot.settings.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    @Test func adamagedBlobIsKeptAndReportedOnce() throws {
        let defaults = scratch()
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

    /// A second bad blob must not overwrite the good copy the first one saved.
    @Test func aSecondFailureLeavesTheFirstCopyAlone() throws {
        let defaults = scratch()
        let original = Data("{ the operator's real settings".utf8)
        defaults.set(original, forKey: CaptureSettings.defaultsKey)
        _ = CaptureSettings.load(from: defaults)

        defaults.set(Data("{ damaged again".utf8),
                     forKey: CaptureSettings.defaultsKey)
        let again = CaptureSettings.load(from: defaults)
        #expect(again.unreadable == nil)
        #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == original,
                "the recoverable copy was replaced by a later bad one")
    }

    /// Nothing stored at all is not damage — it is a first launch.
    @Test func afreshInstallKeepsNothingAndReportsNothing() throws {
        let defaults = scratch()
        let load = CaptureSettings.load(from: defaults)
        #expect(load.unreadable == nil)
        #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == nil)
    }

    /// And a blob that DOES decode is left entirely alone.
    @Test func agoodBlobIsNotTouched() throws {
        let defaults = scratch()
        var settings = CaptureSettings()
        settings.capture.destinationPath = "/tmp/takeshot-recovery"
        settings.save(to: defaults)

        let load = CaptureSettings.load(from: defaults)
        #expect(load.unreadable == nil)
        #expect(load.settings.capture.destinationPath == "/tmp/takeshot-recovery")
        #expect(defaults.data(forKey: CaptureSettings.unreadableKey) == nil)
    }
}
