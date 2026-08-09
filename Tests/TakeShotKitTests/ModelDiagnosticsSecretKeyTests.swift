import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which settings keys are credentials.
///
/// Its own suite because it is its own decision. Everything in
/// `ModelDiagnosticsTests` is about what the bundle REPORTS; this is the one
/// rule that decides what never reaches it, it is the only thing standing
/// between `remotePIN` and a file that gets emailed, and it is the rule that
/// was wrong — a raw substring match dropped `keepInMenuBar` from every bundle
/// ever produced, because "kee-PIN-menubar" contains the marker across a word
/// join.
@Suite struct ModelDiagnosticsSecretKeyTests {
    /// Secrets go by KEY NAME, not by value. A four-digit PIN cannot be removed
    /// by searching for its digits — "1080" is also a raster — so the rule has
    /// to be structural, and it has to catch a credential nobody has added yet.
    @Test func secretsAreRecognisedByName() {
        #expect(DiagnosticsRedaction.isSecretKey("remotePIN"))
        #expect(DiagnosticsRedaction.isSecretKey("apiToken"))
        #expect(DiagnosticsRedaction.isSecretKey("SharedSecret"))
        #expect(DiagnosticsRedaction.isSecretKey("password"))
        #expect(!DiagnosticsRedaction.isSecretKey("remotePort"))
        #expect(!DiagnosticsRedaction.isSecretKey("chromaKeyTolerance"))
        #expect(!DiagnosticsRedaction.isSecretKey("destinationPath"))
    }

    /// The two keys that name the rule, together, because the rule is exactly
    /// the line between them.
    ///
    /// `keepInMenuBar` lowercases to "kee-pin-menubar". Under a plain
    /// `contains` it was dropped from every diagnostics bundle ever produced —
    /// not a leak, but the bundle exists to report the app's state, and a
    /// setting that silently never appears is a blind spot in the one artifact
    /// a bug report carries. `remotePIN` has to keep going.
    @Test func theRuleSeparatesAPinFromAKeepIn() {
        #expect(!DiagnosticsRedaction.isSecretKey("keepInMenuBar"),
                "an ordinary setting was taken for a credential")
        #expect(DiagnosticsRedaction.isSecretKey("remotePIN"),
                "the PIN stopped being dropped")
    }

    /// Where a marker sits decides, and the components say where.
    @Test func aMarkerCountsOnlyWhenItStartsAComponent() {
        #expect(DiagnosticsRedaction.components(of: "remotePIN")
            == ["remote", "pin"])
        #expect(DiagnosticsRedaction.components(of: "keepInMenuBar")
            == ["keep", "in", "menu", "bar"])
        // a capital run stays one component, so an acronym is not spelled out
        #expect(DiagnosticsRedaction.components(of: "remotePINCode")
            == ["remote", "pin", "code"])
        #expect(DiagnosticsRedaction.components(of: "PINCode")
            == ["pin", "code"])
        #expect(DiagnosticsRedaction.components(of: "password")
            == ["password"])
    }

    /// Loose in the direction that matters: a marker is a PREFIX of a
    /// component, so plurals and suffixed forms are still caught. A false
    /// positive costs a line of a diagnostic; a false negative costs a
    /// credential.
    @Test func aSuffixedOrPluralCredentialIsStillACredential() {
        #expect(DiagnosticsRedaction.isSecretKey("clientSecrets"))
        #expect(DiagnosticsRedaction.isSecretKey("pinCode"))
        #expect(DiagnosticsRedaction.isSecretKey("uploadTokenB"))
        #expect(DiagnosticsRedaction.isSecretKey("userPasswordHash"))
        // …and a word that merely contains a marker mid-component is not one
        #expect(!DiagnosticsRedaction.isSecretKey("spinnerStyle"))
        #expect(!DiagnosticsRedaction.isSecretKey("takeCount"))
    }
}
