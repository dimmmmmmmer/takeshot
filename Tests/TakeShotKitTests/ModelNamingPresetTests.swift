import CaptureCore
import Foundation
import Testing
@testable import TakeShotKit

/// `NamingPreset` claims to be "verified against real camera filenames
/// (NamingEngineTests.vendorPresetExactNames)", but that suite hard-codes its
/// own template strings — and it still spells them with the retired
/// `{date6}`/`{time6}` placeholders, not the `{yymmdd}`/`{hhmmss}` the presets
/// actually carry. Nothing was driving `NamingPreset.all` itself.
///
/// These names go on the deliverables the post house matches against the camera
/// originals, so each preset is run through the real engine here.
struct ModelNamingPresetTests {
    /// A date/time picked so every vendor field is distinguishable:
    /// 2025-10-31 20:15:35.
    private func date(y: Int, mo: Int, d: Int, h: Int = 12, mi: Int = 34,
                      s: Int = 0) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        guard let date = Calendar(identifier: .gregorian).date(from: components)
        else { fatalError("bad fixture date") }
        return date
    }

    private func preset(_ key: String) throws -> NamingPreset {
        try #require(NamingPreset.all.first { $0.key == key },
                     "preset \(key) is gone")
    }

    private func name(_ preset: NamingPreset, roll: String, clip: Int,
                      cam: String = "A", postfix: String = "",
                      prefix: String = "", date: Date) -> String {
        NamingEngine(template: preset.template).fileName(for: NamingContext(
            project: prefix, date: date, take: clip, reel: roll, camera: cam,
            postfix: postfix, clipPadding: preset.clipDigits))
    }

    /// Each expected name is a filename a real camera of that make produced.
    @Test func everyPresetProducesItsVendorFilename() throws {
        #expect(name(try preset("preset_takeshot"), roll: "001", clip: 1,
                     postfix: "night", prefix: "Film",
                     date: date(y: 2023, mo: 7, d: 15))
                == "Film_A001C01_night")

        #expect(name(try preset("preset_arri"), roll: "001", clip: 2,
                     postfix: "R1Y2", date: date(y: 2025, mo: 9, d: 4))
                == "A001C002_250904_R1Y2")

        #expect(name(try preset("preset_arri35"), roll: "0003", clip: 4,
                     postfix: "h1ENU",
                     date: date(y: 2025, mo: 10, d: 31, h: 20, mi: 15, s: 35))
                == "A_0003C004_251031_201535_h1ENU")

        #expect(name(try preset("preset_red"), roll: "108", clip: 64,
                     postfix: "UM", date: date(y: 2023, mo: 4, d: 16))
                == "A108_A064_0416UM")

        #expect(name(try preset("preset_sony_venice"), roll: "001", clip: 40,
                     postfix: "58", date: date(y: 2026, mo: 2, d: 26))
                == "A001C040_26022658")

        #expect(name(try preset("preset_sony_alpha"), roll: "", clip: 1,
                     date: date(y: 2023, mo: 7, d: 15))
                == "C0001")

        #expect(name(try preset("preset_bmd"), roll: "001", clip: 65,
                     date: date(y: 2023, mo: 11, d: 30, h: 18, mi: 23))
                == "A001_11301823_C065")

        #expect(name(try preset("preset_canon"), roll: "0002", clip: 188,
                     postfix: "5S",
                     date: date(y: 2026, mo: 3, d: 27, h: 19, mi: 27, s: 7))
                == "A_0002C188X260327_1927075S_CANON")
    }

    /// `applyNamingPreset` writes `clipDigits` into `clipPadWidth`, which
    /// `clipPadWidthEffective` clamps to 2…4. A preset outside that range would
    /// be silently clamped and quietly stop matching the vendor's numbering.
    @Test func clipDigitsSurviveTheSettingsClamp() {
        for preset in NamingPreset.all {
            var settings = CaptureSettings()
            settings.clipPadWidth = preset.clipDigits
            let effective = settings.clipPadWidthEffective
            #expect(effective == preset.clipDigits,
                    "\(preset.key) asks for \(preset.clipDigits) clip digits, gets \(effective)")
        }
    }

    /// The roll width is applied by reformatting the trailing digits of the
    /// current roll; a zero or negative width would produce an unpadded or
    /// malformed roll.
    @Test func rollDigitsAreAUsableWidth() {
        for preset in NamingPreset.all {
            guard let rollDigits = preset.rollDigits else { continue }
            #expect(rollDigits >= 1 && rollDigits <= 6,
                    "\(preset.key) roll width \(rollDigits)")
            #expect(FieldStepper.stepTrailingNumber(
                String(format: "%0\(rollDigits)d", 1), by: 1).count == rollDigits)
        }
    }

    /// `key` is both the localization key and the `Identifiable` id: a duplicate
    /// breaks the Settings picker's ForEach, and a missing string renders the
    /// raw key as the menu item.
    @Test func presetKeysAreUniqueAndLocalizedInEveryLanguage() throws {
        let keys = NamingPreset.all.map(\.key)
        #expect(Set(keys).count == keys.count, "duplicate preset keys in \(keys)")
        #expect(NamingPreset.all.map(\.id) == keys)

        let bundle = Bundle.module
        for language in ["en", "ru"] {
            let path = try #require(bundle.path(forResource: language,
                                                ofType: "lproj"))
            let strings = try #require(NSDictionary(
                contentsOfFile: path + "/Localizable.strings") as? [String: String])
            let missing = keys.filter { strings[$0] == nil }
            #expect(missing.isEmpty,
                    "\(language) is missing \(missing.joined(separator: ", "))")
        }
    }

    /// Every placeholder a preset uses must be one the engine substitutes —
    /// an unknown one is stripped, so a typo shows up as a silently shorter name
    /// rather than an error.
    @Test func presetTemplatesUseOnlyKnownPlaceholders() {
        let known = Set(NamingEngine.placeholders)
        for preset in NamingPreset.all {
            let unknown = Self.placeholders(in: preset.template)
                .filter { !known.contains($0) }
            #expect(unknown.isEmpty,
                    "\(preset.key) uses \(unknown.joined(separator: ", "))")
        }
    }

    /// Every "{…}" run in a template, in order.
    private static func placeholders(in template: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in template {
            switch character {
            case "{": current = "{"
            case "}":
                if var open = current {
                    open.append("}")
                    found.append(open)
                    current = nil
                }
            default: current?.append(character)
            }
        }
        return found
    }
}

/// The camera label is typed by hand and lands verbatim in filenames that travel
/// to other people's machines, so the field sanitizes as you type.
struct ModelCameraLabelTests {
    @Test func keepsOnlyUppercaseLatinLetters() {
        #expect(NamingFieldsView.camSanitized("a") == "A")
        #expect(NamingFieldsView.camSanitized("Cam B") == "CAMB")
        #expect(NamingFieldsView.camSanitized("A1") == "A")
        #expect(NamingFieldsView.camSanitized("A-B") == "AB")
    }

    /// A Cyrillic "А" looks identical to a Latin "A" on the keycap and is the
    /// realistic way a non-ASCII character reaches a filename here.
    @Test func stripsLookalikeAndNonLatinCharacters() {
        #expect(NamingFieldsView.camSanitized("А") == "")       // Cyrillic А
        #expect(NamingFieldsView.camSanitized("Кам") == "")
        #expect(NamingFieldsView.camSanitized("Aк") == "A")
        #expect(NamingFieldsView.camSanitized("") == "")
        #expect(NamingFieldsView.camSanitized("  ") == "")
    }
}
