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
}
