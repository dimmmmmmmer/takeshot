import AppKit
import Foundation

/// "Show it in the Finder", in one place.
///
/// Every folder the app hands to the Finder goes through here: the record
/// folder from the File menu and the takes panel, the offload sheet's source
/// and destination tiles, a finished destination's result card, the verify
/// sheet's disk, and a row of the offload history. They were four call sites
/// with three different behaviours between them.
///
/// **Why a seam and not just a call.** `NSWorkspace` opens a real Finder window
/// on the machine running the suite, and half of what is worth asserting here
/// is exactly WHICH folder a button reaches for — the copy's own folder once it
/// exists, the disk before that. So the tests replace `handler` and read back
/// the URLs. Main-actor state, and the suite is serial, so a substitution
/// cannot leak sideways into another test.
@MainActor
enum FinderOpen {
    /// What actually opens the folder. Replaced by the suite; never by the app.
    static var handler: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Open a folder that is already there.
    ///
    /// A folder that is not is silently nothing: an offload destination whose
    /// SSD has been unplugged is the common case for an old history row, and
    /// handing the Finder a vanished path opens a window on nothing — which
    /// reads as the app being broken rather than the disk being absent.
    static func folder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        handler(url)
    }

    /// Open a folder the app owns, creating it first.
    ///
    /// Only for folders this app is the author of — the record folder, the LUT
    /// library. Creating a missing OFFLOAD destination would be the wrong
    /// favour: an empty folder appearing where the copies were supposed to be
    /// is worse than being told nothing happened.
    static func ownFolder(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        handler(url)
    }
}
