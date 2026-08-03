import CR3D
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Everything about R3D support that can be checked WITHOUT an .r3d file.
///
/// Which is most of it, and deliberately so: there is no way to synthesize an
/// R3D — no encoder exists outside a RED camera, and RED's SDK ships no sample
/// clip — so the decode itself is only ever exercised by pointing
/// `takeshot-r3d` at real footage. Everything the app decides ABOUT a clip is
/// arranged so it can be tested here: the scale rule, the spanning-file rule,
/// the colour statement, the settings, and the failure text. This suite also has
/// to pass in a build made with no SDK at all, which is what CI and a public
/// release are.
struct ModelR3DClipTests {
    // MARK: - the decode scale

    /// The auto rule: the most reduction that still fills a 1080-class viewer.
    /// An 8K clip decoded full costs sixteen times a quarter-res decode for a
    /// window that cannot show the difference.
    @Test func autoScaleTakesTheMostReductionThatStillFills1080() {
        let auto = { (width: UInt32) in
            CR3DClip.divisor(for: .auto, width: width)
        }
        #expect(auto(8192) == 4, "8K wants a quarter: 2048 across")
        #expect(auto(6144) == 2, "6K at a quarter is 1536 — under the viewer")
        #expect(auto(4096) == 2)
        #expect(auto(2048) == 1)
        #expect(auto(1920) == 1)
        // Never reduce below the viewer, however small the clip is.
        #expect(auto(1280) == 1)
        #expect(auto(640) == 1)
    }

    /// An explicit choice is honoured as given — that is the point of offering
    /// it to an operator checking critical focus.
    @Test func anExplicitScaleIsTakenLiterally() {
        #expect(CR3DClip.divisor(for: .full, width: 8192) == 1)
        #expect(CR3DClip.divisor(for: .half, width: 8192) == 2)
        #expect(CR3DClip.divisor(for: .quarter, width: 8192) == 4)
        #expect(CR3DClip.divisor(for: .eighth, width: 8192) == 8)
        // and on a small clip too: the operator asked, not the heuristic
        #expect(CR3DClip.divisor(for: .eighth, width: 1920) == 8)
    }

    /// The setting maps onto the bridge's scale one-for-one, and its default is
    /// auto. A silent mismatch here is a player that decodes 8K full-res on
    /// every clip and nobody knowing why it stutters.
    @Test func theDecodeScaleSettingDefaultsToAutoAndRoundTrips() {
        var settings = CaptureSettings()
        #expect(settings.r3dDecodeScale == nil)
        #expect(settings.r3dDecodeScaleEffective == .auto)
        #expect(R3DDecodeScale.auto.divisor == 0, "0 = let the clip decide")

        for scale in R3DDecodeScale.allCases {
            settings.r3dDecodeScale = scale.rawValue
            #expect(settings.r3dDecodeScaleEffective == scale)
        }
        // A value from a newer build falls back rather than trapping.
        settings.r3dDecodeScale = "sixteenth"
        #expect(settings.r3dDecodeScaleEffective == .auto)
    }

    /// Optional, like every settings field added since the first release: a blob
    /// saved before these fields existed still has to decode, and an untouched
    /// install must not write them at all.
    @Test func theR3DSettingsSurviveABlobSavedWithoutThem() throws {
        let encoded = try JSONEncoder().encode(CaptureSettings())
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("r3dDecodeScale"),
                "an untouched install has to write no key at all")
        #expect(!text.contains("r3dApplyCameraLUT"))

        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "r3dDecodeScale")
        object.removeValue(forKey: "r3dApplyCameraLUT")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let settings = try JSONDecoder().decode(CaptureSettings.self,
                                                from: stripped)
        #expect(settings.r3dDecodeScale == nil)
        #expect(settings.r3dApplyCameraLUT == nil)
        #expect(settings.r3dDecodeScaleEffective == .auto)
    }

    // MARK: - the camera look

    /// Off by default, and the OFF state is what an untouched install stores —
    /// nil, not false, so a later change of default reaches it.
    @Test func theCameraLookIsOffUntilAskedFor() {
        var settings = CaptureSettings()
        #expect((settings.r3dApplyCameraLUT ?? false) == false)
        settings.r3dApplyCameraLUT = true
        #expect(settings.r3dApplyCameraLUT == true)
    }

    /// The viewer states its colour space. This app said nothing about colour to
    /// the operator before R3D, and R3D is the first format where saying nothing
    /// would be a lie — its native output is REDWideGamutRGB / Log3G10.
    @Test func theColorNoteStatesTheTransformAndTheScale() {
        let note = RawColorNote(transform: "Rec.709 / BT.1886",
                                pipeline: "IPP2", scaleDivisor: 4,
                                cameraLUTName: nil, cameraLUTApplied: false)
        let lines = note.operatorLines
        #expect(lines.count == 2)
        #expect(lines[0].contains("Rec.709 / BT.1886"))
        #expect(lines[0].contains("IPP2"))
        #expect(lines[1].contains("1/4"))
    }

    /// A full-res decode says nothing about scale — there is nothing to disclose.
    @Test func aFullResDecodeMentionsNoScale() {
        let note = RawColorNote(transform: "Rec.709", pipeline: "Legacy",
                                scaleDivisor: 1, cameraLUTName: nil,
                                cameraLUTApplied: false)
        #expect(note.operatorLines.count == 1)
        #expect(!note.operatorLines[0].contains("1/"))
    }

    /// A clip carrying a look the viewer is NOT applying has to say so. Silently
    /// dropping the DP's LUT and silently baking it are the same failure.
    @Test func aWithheldCameraLookIsDeclaredEitherWay() {
        let withheld = RawColorNote(transform: "Rec.709 / BT.1886",
                                    pipeline: "IPP2", scaleDivisor: 1,
                                    cameraLUTName: "showlook.cube",
                                    cameraLUTApplied: false)
        let applied = RawColorNote(transform: "Rec.709 / BT.1886",
                                   pipeline: "IPP2", scaleDivisor: 1,
                                   cameraLUTName: "showlook.cube",
                                   cameraLUTApplied: true)
        for note in [withheld, applied] {
            #expect(note.operatorLines.contains { $0.contains("showlook.cube") },
                    "the LUT has to be named either way")
        }
        #expect(withheld.operatorLines.last != applied.operatorLines.last,
                "applied and not applied must not read the same")
    }

    /// Both languages have to be able to say it — a raw key on the badge is a
    /// viewer that tells the operator nothing.
    @Test func theColorStatementIsTranslated() {
        let note = RawColorNote(transform: "Rec.709 / BT.1886",
                                pipeline: "IPP2", scaleDivisor: 2,
                                cameraLUTName: "look.cube",
                                cameraLUTApplied: false)
        for language in [AppLanguage.english, .russian] {
            L10n.apply(language)
            for line in note.operatorLines {
                #expect(!line.contains("raw_"), "raw key in \(language): \(line)")
                #expect(!line.isEmpty)
            }
        }
        L10n.apply(.english)
    }

    // MARK: - spanning clips

    /// A RED clip past 4 GB is A001_C001_0101XX_001.R3D … _999.R3D and all of it
    /// is ONE clip. Listing every part fills the takes panel with rows that open
    /// identical footage.
    @Test func continuationPartsAreHiddenWhenTheirFirstPartIsPresent() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-span")
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["A001_C001_0101XX_001.R3D", "A001_C001_0101XX_002.R3D",
                     "A001_C001_0101XX_017.R3D"]
        for name in names {
            try Data([0x00]).write(to: folder.appendingPathComponent(name))
        }
        #expect(!R3DSource.isContinuationPart(
            folder.appendingPathComponent(names[0])),
            "the first part IS the clip")
        #expect(R3DSource.isContinuationPart(
            folder.appendingPathComponent(names[1])))
        #expect(R3DSource.isContinuationPart(
            folder.appendingPathComponent(names[2])))
    }

    /// Never hide footage. A part whose `_001` sibling is missing — a partial
    /// copy, a hand-sorted folder — is the only copy of that material there is.
    @Test func anOrphanedPartIsStillListed() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-orphan")
        defer { try? FileManager.default.removeItem(at: folder) }
        let orphan = folder.appendingPathComponent("A001_C001_0101XX_004.R3D")
        try Data([0x00]).write(to: orphan)
        #expect(!R3DSource.isContinuationPart(orphan))
    }

    /// Nikon's R3D NE clips are one file each (DSC_0001.R3D) and their suffix is
    /// four digits, not three. Hiding DSC_0002.R3D would hide a whole take.
    @Test func nikonSingleFileClipsAreNeverTreatedAsContinuations() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-ne")
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["DSC_0001.R3D", "DSC_0002.R3D"] {
            try Data([0x00]).write(to: folder.appendingPathComponent(name))
        }
        #expect(!R3DSource.isContinuationPart(
            folder.appendingPathComponent("DSC_0002.R3D")))
    }

    /// The rule is filename arithmetic on purpose — it has to work in a build
    /// with no SDK, and it must not claim anything about other formats.
    @Test func theContinuationRuleOnlyAppliesToR3D() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-other")
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["A001_C001_0101XX_001.mov", "A001_C001_0101XX_002.mov"] {
            try Data([0x00]).write(to: folder.appendingPathComponent(name))
        }
        #expect(!R3DSource.isContinuationPart(
            folder.appendingPathComponent("A001_C001_0101XX_002.mov")))
    }

    /// And the walk actually applies it: one clip, one row.
    @Test func theFolderScanListsOneRowPerSpanningClip() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-walk")
        defer { try? FileManager.default.removeItem(at: folder) }
        for part in 1...12 {
            let name = String(format: "A001_C001_0101XX_%03d.R3D", part)
            try Data([0x00]).write(to: folder.appendingPathComponent(name))
        }
        // Backdated so the 3-second settle rule does not call them "still
        // being written" — see CaptureController.classify.
        let old = Date().addingTimeInterval(-600)
        for url in try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: url.path)
        }
        let (files, busy) = CaptureController.findForeignVideos(
            root: folder, excluding: [])
        #expect(files.count == 1, "12 parts of one clip listed as \(files.count)")
        #expect(files.first?.lastPathComponent == "A001_C001_0101XX_001.R3D")
        #expect(!busy)
    }

    // MARK: - honest failure

    /// Whatever this build is, an operator who opens a bad .r3d gets a sentence.
    /// Which sentence depends on whether RED's SDK is present, and the two are
    /// different problems: "this app has no decoder" is answered by installing
    /// the SDK, "this clip is truncated" by re-copying the card.
    @MainActor
    @Test func aBadR3DAlwaysExplainsItself() throws {
        let folder = try MediaFixtures.makeDirectory("r3d-bad")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("A001_C001_0101XX_001.R3D")
        try Data(repeating: 0x00, count: 4096).write(to: clip)

        var error: String?
        let model = RawPlayerModel(url: clip, error: &error)
        #expect(model == nil, "a file that is not an R3D must not open")
        let reason = try #require(error)
        #expect(!reason.isEmpty)
        if CR3DClip.isSDKAvailable() {
            #expect(reason.contains("A001_C001_0101XX_001.R3D"),
                    "a real bridge names the file it refused: \(reason)")
        } else {
            #expect(reason.hasPrefix(L("r3d_sdk_unavailable")),
                    "a stub build says the SDK is missing: \(reason)")
            #expect(reason.count > L("r3d_sdk_unavailable").count,
                    "and appends why: \(reason)")
        }
    }

    /// The stub's own answer, independent of which build ran the suite: a bridge
    /// that is not there says so in one sentence, not by returning nil silently.
    @Test func theBridgeSaysWhetherItIsThere() {
        if CR3DClip.isSDKAvailable() {
            #expect(CR3DClip.unavailableReason() == nil)
            #expect(CR3DClip.sdkVersion()?.isEmpty == false,
                    "a working bridge can name its SDK version")
        } else {
            let reason = CR3DClip.unavailableReason()
            #expect(reason?.isEmpty == false)
        }
    }

    // MARK: - the format badge

    /// One spelling of the short format for every engine. There were two — the
    /// RAW engine rounded unconditionally, the AVFoundation path rounded only
    /// within 0.05 — so a rate far enough off an integer read one way for a take
    /// and another for a RED clip. The near-integer rates cameras actually shoot
    /// (23.976, 29.97) round to what an operator says out loud.
    @Test func theShortFormatBadgeHasOneSpelling() {
        #expect(CaptureController.shortFormat(height: 1080, fps: 25) == "1080p25")
        #expect(CaptureController.shortFormat(height: 2160, fps: 23.976)
            == "2160p24", "23.976 is 24 on a badge")
        #expect(CaptureController.shortFormat(height: 1080, fps: 29.97)
            == "1080p30")
        // Far enough off an integer to be worth the decimals — this is where the
        // two formatters used to disagree.
        #expect(CaptureController.shortFormat(height: 2160, fps: 23.9)
            == "2160p23.90")
        #expect(CaptureController.shortFormat(height: 1080, fps: 0) == "1080p?")
    }
}
