import CDeckLink
import Foundation

/// Why the app can or cannot see a Blackmagic board, stated as one of four
/// answers instead of two booleans the reader has to combine themselves.
///
/// The fourth one is the reason this type exists. A hardened-runtime binary
/// without `disable-library-validation` cannot load a framework signed by
/// another team, and DeckLinkAPI.framework IS another team's — so an app that
/// was compiled with the SDK, on a machine where Desktop Video is installed and
/// working, reports no devices at all and looks exactly like a machine with no
/// Desktop Video on it. That mis-diagnosis cost a day on set. The three inputs
/// tell the two apart: framework on disk + compiled in + still not loaded means
/// the signature, not the install.
///
/// Pure, and separated from the probe below, so every branch can be asserted
/// without owning four differently signed builds.
enum DeckLinkDiagnosis: String, Codable, Sendable {
    /// Built without the SDK headers — `vendor/DeckLinkSDK/include` was empty.
    case stub
    /// Compiled in and the runtime answered: this build can see boards.
    case loaded
    /// Compiled in, but DeckLinkAPI.framework is not on the machine.
    case runtimeMissing
    /// Compiled in, the framework IS on the machine, and it still did not load.
    case signatureSuspect

    static func of(compiledWithSDK: Bool, runtimeLoaded: Bool,
                   frameworkPresent: Bool) -> DeckLinkDiagnosis {
        guard compiledWithSDK else { return .stub }
        if runtimeLoaded { return .loaded }
        return frameworkPresent ? .signatureSuspect : .runtimeMissing
    }

    /// One line, in English like the rest of the bundle, saying what to do
    /// about it. The wording follows `takeshot-devices`, which is the other
    /// place this same question gets answered.
    var explanation: String {
        switch self {
        case .stub:
            return "Built WITHOUT the DeckLink SDK (stub build). No board can "
                + "be seen by this binary at all. Put the SDK headers in "
                + "vendor/DeckLinkSDK/include and rebuild."
        case .loaded:
            return "Compiled with the SDK and the Desktop Video runtime "
                + "loaded. Device visibility is working."
        case .runtimeMissing:
            return "Compiled with the SDK, but DeckLinkAPI.framework is not "
                + "installed. Install Blackmagic Desktop Video."
        case .signatureSuspect:
            return "SIGNATURE SUSPECT: compiled with the SDK, "
                + "DeckLinkAPI.framework IS installed, and it still did not "
                + "load. This is the hardened-runtime library-validation trap "
                + "— a binary signed with the hardened runtime and no "
                + "com.apple.security.cs.disable-library-validation "
                + "entitlement refuses Blackmagic's framework and the app is "
                + "device-blind. Re-sign ad hoc without the hardened runtime, "
                + "or with a Developer ID and that entitlement."
        }
    }
}

/// The same four answers as something to SHOW the operator, beside the device
/// picker and over the picture.
///
/// Separate from `explanation` above rather than a translation of it, because
/// the two are read by different people. The bundle is read by whoever the
/// operator sends it to: it names header directories and re-signing flags. What
/// the operator gets is the one fact they cannot deduce from the device list in
/// front of them, and the one thing that would change it.
///
/// `.loaded` deliberately says NOTHING. This app's users are professionals —
/// "the build works" is not news, and an empty list of boards on a build that
/// can see boards already means exactly what it says.
extension DeckLinkDiagnosis {
    /// Localization keys for the notice, or nil when there is nothing
    /// non-obvious to say. Internal so a test can hold them against both
    /// .strings files rather than against whatever this machine happens to be.
    var noticeKeys: (title: String, detail: String)? {
        switch self {
        case .loaded:
            return nil
        case .stub:
            return ("decklink_stub_title", "decklink_stub_detail")
        case .runtimeMissing:
            return ("decklink_runtime_missing_title",
                    "decklink_runtime_missing_detail")
        case .signatureSuspect:
            return ("decklink_signature_suspect_title",
                    "decklink_signature_suspect_detail")
        }
    }

    /// One line naming what is wrong with this build or this machine.
    var noticeTitle: String? { noticeKeys.map { L($0.title) } }

    /// …and one saying what would change it. Always present when the title is:
    /// a fault an operator can do nothing about is a fault worth naming the
    /// remedy for, and for a downloaded stub build the remedy IS the story.
    var noticeDetail: String? { noticeKeys.map { L($0.detail) } }
}

/// The live answers, read off this machine. Kept apart from the reasoning above
/// so the reasoning stays testable.
enum DeckLinkProbe {
    /// Where Blackmagic Desktop Video installs its runtime.
    static let frameworkPath = "/Library/Frameworks/DeckLinkAPI.framework"

    /// Whether the framework is on disk. A plain stat — nothing is dlopened
    /// here, so asking the question cannot itself change the answer.
    static var frameworkPresent: Bool {
        FileManager.default.fileExists(atPath: frameworkPath)
    }

    /// Desktop Video's version, from the framework's own Info.plist; nil when
    /// it is not installed. Read as a bundle rather than by running
    /// `DesktopVideoUpdater` or any other tool — a diagnostic does not spawn
    /// processes on a shooting machine.
    static var desktopVideoVersion: String? {
        guard let bundle = Bundle(path: frameworkPath) else { return nil }
        let info = bundle.infoDictionary
        return info?["CFBundleShortVersionString"] as? String
            ?? info?["CFBundleVersion"] as? String
    }

    static var diagnosis: DeckLinkDiagnosis {
        .of(compiledWithSDK: CDLDeviceManager.isCompiledWithSDK(),
            runtimeLoaded: CDLDeviceManager.isSDKAvailable(),
            frameworkPresent: frameworkPresent)
    }

    /// The verdict the app shows, and the seam a test uses to show the states
    /// this machine is not in.
    ///
    /// It lives here rather than on `CaptureController` because it is not app
    /// state: none of the three facts behind it can change without an install
    /// and a relaunch, so a `@Published` property would be one that never
    /// publishes. Read once per process, because `isSDKAvailable()` creates and
    /// releases a DeckLink iterator and a view body must not.
    ///
    /// `nonisolated(unsafe)`: written only by a test, before the views that read
    /// it exist, and never while anything else is running — the same contract
    /// the backend list and the volume watch are injected under.
    nonisolated(unsafe) private static var cached: DeckLinkDiagnosis?

    static var current: DeckLinkDiagnosis {
        if let cached { return cached }
        let answer = diagnosis
        cached = answer
        return answer
    }

    /// Put the UI into a state this build is not in. The alternative is owning
    /// four differently signed builds, and a test that asserted against the host
    /// would claim one thing here and another on a runner with no SDK.
    static func overrideDiagnosis(_ value: DeckLinkDiagnosis?) {
        cached = value
    }
}
