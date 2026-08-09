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
}
