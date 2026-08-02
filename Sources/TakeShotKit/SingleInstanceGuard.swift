import AppKit
import Foundation

/// One TakeShot per machine.
///
/// A second window is a preview that misbehaves; a second PROCESS is the same
/// problem one level up and worse. Two copies would open the same DeckLink
/// board — the second `startCapture` takes the input away from the one that is
/// rolling — write takes into the same record folder under the same clip
/// numbers, and race each other's `takeshot-log.csv` writes. Neither copy can
/// detect any of that from the inside.
///
/// macOS itself only refuses a duplicate launch of a bundled app through
/// LaunchServices (double-clicking the .app twice). `open -n`, a second copy at
/// a different path, and running the binary out of the bundle from a shell —
/// which is exactly the workaround this project documents for ad-hoc signing —
/// all start a second process happily.
///
/// So the check is explicit, and deliberately narrow:
///
/// - It needs a bundle identifier. A bare `swift build` binary has none, so a
///   development run from the command line is never affected.
/// - `TAKESHOT_ALLOW_MULTIPLE=1` opts out. Two builds side by side is a
///   development need (comparing a fix against the shipping app), never an
///   on-set one, and an ad-hoc-signed build is rebuilt and relaunched dozens of
///   times an hour.
enum SingleInstanceGuard {
    /// Environment variable that switches the guard off (see above).
    static let overrideKey = "TAKESHOT_ALLOW_MULTIPLE"

    /// The decision itself, with nothing AppKit in it so the rule can be
    /// asserted without a second process to run it against.
    static func handsOff(bundleID: String?, otherInstances: Int,
                         allowMultiple: Bool) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        guard !allowMultiple else { return false }
        return otherInstances > 0
    }

    /// Read the opt-out. Anything but an explicit "off" value counts as on —
    /// somebody who sets the variable at all means it.
    static func allowsMultiple(_ environment: [String: String]) -> Bool {
        guard let value = environment[overrideKey]?.lowercased() else { return false }
        return !["0", "false", "no", ""].contains(value)
    }

    /// Hand focus to the copy that got here first, and report that this process
    /// should go. Returns false when this is the only copy — the normal case,
    /// and every case in a development build.
    ///
    /// Called before the scene graph exists (see the executable's main.swift):
    /// once `CaptureController` has been constructed it has already adopted a
    /// board and started capturing on it, which is the thing being prevented.
    @MainActor
    static func handOffToRunningInstance(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = bundleID.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { $0.processIdentifier != mine }
        } ?? []
        guard handsOff(bundleID: bundleID, otherInstances: others.count,
                       allowMultiple: allowsMultiple(environment)) else {
            return false
        }
        // The oldest copy, not merely the first the list happens to name: the
        // one that has been running longest is the one that may be recording.
        let first = others.min {
            ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
        }
        first?.activate(options: [.activateAllWindows])
        return true
    }
}
