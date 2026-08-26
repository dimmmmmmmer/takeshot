import Foundation
import Testing
@testable import CaptureCore

struct NamingEngineTests {
    private var date: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 14
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func fullTemplate() {
        let engine = NamingEngine(template: "{scene}_T{take}_{cam}_{tc}")
        let name = engine.fileName(for: NamingContext(
            scene: "12A", take: 3, camera: "A",
            timecode: Timecode(hours: 10, minutes: 20, seconds: 30, frames: 15, fps: 25)))
        #expect(name == "12A_T03_A_10.20.30.15")
    }

    @Test func missingValuesCollapse() {
        let engine = NamingEngine(template: "{scene}_T{take}_{cam}_{tc}")
        let name = engine.fileName(for: NamingContext(scene: "5", take: 1))
        #expect(name == "5_T01")
    }

    @Test func sanitizesForbiddenCharacters() {
        let engine = NamingEngine(template: "{scene}")
        // non-ASCII (Cyrillic) is intentional: verifies sanitize preserves unicode
        // letters while stripping the forbidden / : * ? characters
        let name = engine.fileName(for: NamingContext(
            scene: "INT/КУХНЯ: день*01?"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("*"))
        #expect(!name.contains("?"))
        #expect(name == "INT_КУХНЯ_день_01")
    }

    @Test func unknownPlaceholderRemoved() {
        let engine = NamingEngine(template: "{scene}_{unknown}_T{take}")
        let name = engine.fileName(for: NamingContext(scene: "3", take: 2))
        #expect(name == "3_T02")
    }

    @Test func emptyResultFallsBack() {
        let engine = NamingEngine(template: "{reel}")
        #expect(engine.fileName(for: NamingContext()) == "untitled")
    }

    @Test func datePlaceholder() {
        let engine = NamingEngine(template: "{date}_{scene}")
        let name = engine.fileName(for: NamingContext(date: date, scene: "7"))
        #expect(name == "2026-07-14_7")
    }

    @Test func postfixAndDefaultTemplate() {
        let engine = NamingEngine(template: CaptureSettings().naming.namingTemplate)
        let withPostfix = engine.fileName(for: NamingContext(
            project: "Film", take: 7, reel: "002", camera: "B", postfix: "night"))
        #expect(withPostfix == "Film_B002C07_night")
        // an empty postfix collapses without a trailing separator
        let without = engine.fileName(for: NamingContext(
            project: "Film", take: 7, reel: "002", camera: "B"))
        #expect(without == "Film_B002C07")
    }

    @Test func clipPaddingWidths() {
        let engine = NamingEngine(template: "C{clip}")
        #expect(engine.fileName(for: NamingContext(take: 7)) == "C07")
        #expect(NamingEngine(template: "C{clip}", clipPadding: 3)
            .fileName(for: NamingContext(take: 7)) == "C007")
        #expect(NamingEngine(template: "C{clip}", clipPadding: 4)
            .fileName(for: NamingContext(take: 7)) == "C0007")
        #expect(NamingEngine(template: "C{clip}", clipPadding: 2)
            .fileName(for: NamingContext(take: 1234)) == "C1234")
    }

    @Test func fieldStepperNumbersAndLetters() {
        #expect(FieldStepper.stepTrailingNumber("001", by: 1) == "002")
        #expect(FieldStepper.stepTrailingNumber("009", by: 1) == "010")
        #expect(FieldStepper.stepTrailingNumber("001", by: -1) == "000")
        #expect(FieldStepper.stepTrailingNumber("000", by: -1) == "000")
        #expect(FieldStepper.stepTrailingNumber("A12", by: 1) == "A13")
        #expect(FieldStepper.stepTrailingNumber("ROLL", by: 1) == "ROLL")
        #expect(FieldStepper.stepLetter("A", by: 1) == "B")
        #expect(FieldStepper.stepLetter("Z", by: 1) == "A")
        #expect(FieldStepper.stepLetter("A", by: -1) == "Z")
        #expect(FieldStepper.stepLetter("CAM B", by: 1) == "CAM C")
    }

    @Test func cubeLUTParsing() throws {
        let cube = """
        # comment
        TITLE "test"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let lut = try CubeLUT.parse(cube, name: "test")
        #expect(lut.size == 2)
        // 8 nodes * RGBA float32
        #expect(lut.data.count == 8 * 4 * 4)
        #expect(lut.makeFilter() != nil)

        #expect(throws: CubeLUT.ParseError.self) {
            _ = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0")
        }
        #expect(throws: CubeLUT.ParseError.self) {
            _ = try CubeLUT.parse("0 0 0\n1 1 1")
        }
    }

    /// Each preset — against a real camera filename (2023-07-15 12:34).
    @Test func vendorPresetExactNames() {
        // date/time from real user examples, where they matter:
        // ARRI35 A_0003C004_251031_201535..., Canon ...X260327_192707...
        // "yyyy-MM-dd HH:mm:ss" rather than six separate components: the
        // expectations below are real camera filenames, and the date reads
        // straight off them this way.
        func name(_ template: String, roll: String, clip: Int, pad: Int,
                  cam: String = "A", postfix: String = "", prefix: String = "",
                  at moment: String = "2023-07-15 12:34:00") -> String {
            let parts = moment.split(whereSeparator: { " -:".contains($0) })
                .compactMap { Int($0) }
            var c = DateComponents()
            (c.year, c.month, c.day) = (parts[0], parts[1], parts[2])
            (c.hour, c.minute, c.second) = (parts[3], parts[4], parts[5])
            let date = Calendar(identifier: .gregorian).date(from: c)!
            return NamingEngine(template: template, clipPadding: pad)
                .fileName(for: NamingContext(
                    project: prefix, date: date, take: clip, reel: roll,
                    camera: cam, postfix: postfix))
        }

        // ARRI classic: A001C002_250904_R1Y2 (user example)
        #expect(name("{cam}{roll}C{clip}_{date6}_{postfix}",
                     roll: "001", clip: 2, pad: 3, postfix: "R1Y2",
                     at: "2025-09-04 12:34:00")
                == "A001C002_250904_R1Y2")
        // ARRI Alexa 35: A_0003C004_251031_201535_h1ENU (user example)
        #expect(name("{cam}_{roll}C{clip}_{date6}_{time6}_{postfix}",
                     roll: "0003", clip: 4, pad: 3, postfix: "h1ENU",
                     at: "2025-10-31 20:15:35")
                == "A_0003C004_251031_201535_h1ENU")
        // RED: A108_A064_0416UM (user example, no span segment)
        #expect(name("{cam}{roll}_{cam}{clip}_{date4}{postfix}",
                     roll: "108", clip: 64, pad: 3, postfix: "UM",
                     at: "2023-04-16 12:34:00")
                == "A108_A064_0416UM")
        // Sony: A001C040_26022658 (user example)
        #expect(name("{cam}{roll}C{clip}_{date6}{postfix}",
                     roll: "001", clip: 40, pad: 3, postfix: "58",
                     at: "2026-02-26 12:34:00")
                == "A001C040_26022658")
        // Sony (Legacy): C0001
        #expect(name("C{clip}", roll: "", clip: 1, pad: 4) == "C0001")
        // Blackmagic: A001_11301823_C065 (user example)
        #expect(name("{cam}{roll}_{date4}{time4}_C{clip}",
                     roll: "001", clip: 65, pad: 3,
                     at: "2023-11-30 18:23:00")
                == "A001_11301823_C065")
        // Canon: A_0002C188X260327_1927075S_CANON (user example)
        #expect(name("{cam}_{roll}C{clip}X{date6}_{time6}{postfix}_CANON",
                     roll: "0002", clip: 188, pad: 3, postfix: "5S",
                     at: "2026-03-27 19:27:07")
                == "A_0002C188X260327_1927075S_CANON")
        // TakeShot default: Film_A001C01_night
        #expect(name("{prefix}_{cam}{roll}C{clip}_{postfix}",
                     roll: "001", clip: 1, pad: 2,
                     postfix: "night", prefix: "Film")
                == "Film_A001C01_night")
    }

    @Test func relativeDirectory() {
        let engine = NamingEngine(template: "{scene}")
        let dir = engine.relativeDirectory(for: NamingContext(
            project: "My Film", date: date, scene: "12A"))
        #expect(dir == "My_Film/2026-07-14/12A")
    }

    /// Two keystrokes nothing in the field refuses, and the day's takes were
    /// written into the PARENT of the folder the operator chose: `sanitize` has
    /// no opinion about dots, and only the file-NAME path ran the pass that
    /// trims them.
    @Test func aProjectOfTwoDotsCannotLeaveTheRecordFolder() {
        let engine = NamingEngine(template: "{scene}")
        for escape in ["..", "...", ".", " .. "] {
            let dir: String = engine.relativeDirectory(for: NamingContext(
                project: escape, date: date, scene: escape))
            #expect(dir == "2026-07-14", "a dots-only name is not a level")
            let root: URL = URL(fileURLWithPath: "/Volumes/CARD/rec")
            let resolved: String = root.appendingPathComponent(dir)
                .standardizedFileURL.path
            #expect(resolved.hasPrefix("/Volumes/CARD/rec/"),
                    "the take folder stays inside the record folder")
        }
    }

    /// A leading dot is the milder half of the same gap: footage in a directory
    /// the operator cannot see in Finder.
    @Test func aProjectBeginningWithADotIsNotAHiddenFolder() {
        let engine = NamingEngine(template: "{scene}")
        let dir: String = engine.relativeDirectory(for: NamingContext(
            project: ".hidden", date: date, scene: "12A"))
        #expect(dir == "hidden/2026-07-14/12A",
                "no level of the take folder starts with a dot")
    }

    /// The template is free text in Settings — a plain `TextField`, no input
    /// filter — and `fileName(for:)` sanitized the substituted VALUES only. So
    /// its own literal characters reached the name: a `/` typed into it was a
    /// directory separator, and a pasted newline or NUL a name the file system
    /// refuses outright.
    @Test func theTemplateItselfCannotPutASeparatorInAName() {
        let cases: [(template: String, expected: String)] = [
            ("{cam}/{clip}", "P_A_01"),
            ("{cam}:{clip}", "P_A_01"),
            ("{cam}\u{0}{clip}", "P_A_01"),
            ("{cam}\n{clip}", "P_A_01"),
            ("../{cam}{clip}", "P_A01"),
        ]
        for (template, expected) in cases {
            let engine = NamingEngine(template: template)
            let name: String = engine.fileName(for: NamingContext(
                project: "P", take: 1, camera: "A"))
            #expect(name == expected, "the template cannot forge a path")
        }
    }

    /// And a template that only holds placeholders, separators and letters is
    /// untouched by that pass — every vendor preset has to name exactly what it
    /// always named.
    @Test func theVendorPresetsAreUnchangedByTheTemplatePass() {
        for template in ["{prefix}_{cam}{roll}C{clip}_{postfix}",
                         "{cam}{roll}C{clip}_{yymmdd}_{postfix}",
                         "{cam}_{roll}C{clip}X{yymmdd}_{hhmmss}{postfix}_CANON",
                         "C{clip}"] {
            #expect(NamingEngine.templateSafe(template) == template,
                    "a normal template is passed through unchanged")
        }
    }
}

/// The length rule: what a composed name may be, and what a name over it gives
/// up. Its own suite because it is its own subject — the engine's other tests
/// are about what the template SAYS, and these are about what the file system
/// will accept it saying.
struct NamingLengthTests {
    /// The engine had no length rule at all, and the naming fields have no
    /// input limit either. A pasted project prefix composed a name that
    /// `open(2)` refuses with `ENAMETOOLONG` and `AVAssetWriter.startWriting()`
    /// reports as `NSURLErrorCannotCreateFile` — the take never opens, with the
    /// camera already rolling.
    ///
    /// Both budgets, because macOS and a network share count different things:
    /// 255 UTF-8 bytes is what an SMB/NFS/Linux destination allows, 255
    /// decomposed UTF-16 units is what APFS itself enforces, and neither
    /// implies the other.
    @Test func aPastedPrefixCannotComposeANameTheFileSystemRefuses() {
        let engine = NamingEngine(template: CaptureSettings().naming.namingTemplate)
        let cases: [(name: String, project: String)] = [
            ("ASCII", String(repeating: "X", count: 900)),
            ("Cyrillic", String(repeating: "Щ", count: 900)),
            ("a decomposing letter", String(repeating: "й", count: 900)),
            ("emoji", String(repeating: "\u{1F600}", count: 400)),
        ]
        for (label, project) in cases {
            let name: String = engine.fileName(for: NamingContext(
                project: project, take: 7, reel: "002", camera: "B",
                postfix: "night"))
            #expect(name.utf8.count <= NamingEngine.fileNameByteBudget,
                    "\(label): \(name.utf8.count) bytes")
            #expect(NamingEngine.pathUnits(name) <= NamingEngine.fileNameUnitBudget,
                    "\(label): \(NamingEngine.pathUnits(name)) units")
            // the take is still identifiable: the prefix gave its tail back,
            // the clip number and everything around it did not
            #expect(name.contains("B002C07_night"),
                    "\(label): the take's own fields were cut instead: \(name)")
        }
    }

    /// A cut through the middle of a two-byte Cyrillic letter is not UTF-8 at
    /// all, and a name that is not UTF-8 does not round-trip through the CSV
    /// sidecars — the row in `takeshot-log.csv` would no longer name the file.
    @Test func aShortenedNameIsStillValidUTF8() {
        let engine = NamingEngine(template: "{prefix}_C{clip}")
        // every offset into the budget, so a boundary landing mid-sequence
        // would be hit rather than hoped past
        for letters: Int in 100...200 {
            let name: String = engine.fileName(for: NamingContext(
                project: String(repeating: "Ы", count: letters), take: 3))
            let bytes: [UInt8] = Array(name.utf8)
            #expect(String(bytes: bytes, encoding: .utf8) == name,
                    "\(letters) letters produced bytes that are not UTF-8")
            #expect(!name.unicodeScalars.contains("\u{FFFD}"),
                    "\(letters) letters left a replacement character")
        }
    }

    /// Two long prefixes that differ only past the cut must not become the same
    /// file. A collision after truncation is worse than a shortened name: the
    /// operator would be looking for the second take under the first take's
    /// name, and the writer would be handed a path that already exists.
    ///
    /// Driven onto a real disk rather than compared as strings, because the
    /// guarantee is about FILES: the name goes through `uniqueURL`, which is
    /// what the pipeline uses, and both takes have to end up with their own.
    @Test func twoLongNamesDifferingPastTheCutAreTwoDifferentFiles() throws {
        let root: URL = TestMedia.scratchDirectory("NamingLength")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = NamingEngine(template: CaptureSettings().naming.namingTemplate)
        let head = String(repeating: "Ы", count: 400)
        var written: [URL] = []
        for tail: String in ["_СЦЕНА_ОДИН", "_СЦЕНА_ДВА"] {
            let name: String = engine.fileName(for: NamingContext(
                project: head + tail, take: 4, reel: "002", camera: "B"))
            let url: URL = CapturePipeline.uniqueURL(for: root
                .appendingPathComponent(name).appendingPathExtension("mov"))
            defer { CapturePipeline.releaseReservation(for: url) }
            #expect(FileManager.default.createFile(
                atPath: url.path, contents: Data(tail.utf8)),
                "the file system refused \(url.lastPathComponent.utf8.count) bytes")
            written.append(url)
        }
        #expect(Set(written.map(\.lastPathComponent)).count == 2,
                "both takes were named \(written.first?.lastPathComponent ?? "")")
        for (url, tail) in zip(written, ["_СЦЕНА_ОДИН", "_СЦЕНА_ДВА"]) {
            let back: Data? = FileManager.default.contents(atPath: url.path)
            #expect(back == Data(tail.utf8),
                    "the second take overwrote the first")
        }
    }

    /// The budget leaves room for everything the take path still adds after the
    /// name is composed — the extension, the collision suffix, and the
    /// `_FAILED` rename a broken finalize depends on. Without that headroom a
    /// name at exactly the limit fails to be renamed and the failed take is
    /// re-adopted by the folder scan as if it were good.
    @Test func aNameAtTheBudgetStillFitsEverySuffixTheTakePathAdds() throws {
        let root: URL = TestMedia.scratchDirectory("NamingSuffix")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = NamingEngine(template: "{prefix}_C{clip}")
        let name: String = engine.fileName(for: NamingContext(
            project: String(repeating: "X", count: 900), take: 1))
        #expect(name.utf8.count == NamingEngine.fileNameByteBudget,
                "the budget is not being spent: \(name.utf8.count) bytes")
        let worst: String = name + CapturePipeline.failedTakeSuffix + "_999.mov"
        #expect(worst.utf8.count <= NamingEngine.maximumPathComponentBytes,
                "\(worst.utf8.count) bytes with every suffix on it")
        #expect(FileManager.default.createFile(
            atPath: root.appendingPathComponent(worst).path, contents: Data()),
            "the file system refused the fully suffixed name")
    }

    /// Nothing about a name that already fits changes — the cap is a bound, not
    /// a rewrite, and no shortening marker appears on a normal name.
    @Test func aNameThatFitsIsComposedExactlyAsBefore() {
        let engine = NamingEngine(template: CaptureSettings().naming.namingTemplate)
        let name: String = engine.fileName(for: NamingContext(
            project: "Ночной проект", take: 7, reel: "002", camera: "B",
            postfix: "night"))
        #expect(name == "Ночной_проект_B002C07_night")
        #expect(!name.contains("~"), "an ordinary name carries no cut marker")
    }
}
