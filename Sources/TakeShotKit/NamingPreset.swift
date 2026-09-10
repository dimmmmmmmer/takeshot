import Foundation

/// A vendor naming preset: template + the vendor's digit widths.
/// Verified against real camera filenames (NamingEngineTests.vendorPresetExactNames).
struct NamingPreset: Identifiable {
    /// Localization key, also the stable ID ("preset_arri" …).
    let key: String
    let template: String
    /// Clip-number width (C001 → 3).
    let clipDigits: Int
    /// Vendor roll-number width; nil — leave the current roll untouched.
    let rollDigits: Int?

    var id: String { key }

    static let all: [NamingPreset] = [
        NamingPreset(key: "preset_takeshot",
                     template: "{prefix}_{cam}{roll}C{clip}_{postfix}",
                     clipDigits: 2, rollDigits: 3),
        NamingPreset(key: "preset_arri",
                     template: "{cam}{roll}C{clip}_{yymmdd}_{postfix}",
                     clipDigits: 3, rollDigits: 3),
        NamingPreset(key: "preset_arri35",
                     template: "{cam}_{roll}C{clip}_{yymmdd}_{hhmmss}_{postfix}",
                     clipDigits: 3, rollDigits: 4),
        NamingPreset(key: "preset_red",
                     template: "{cam}{roll}_{cam}{clip}_{mmdd}{postfix}",
                     clipDigits: 3, rollDigits: 3),
        NamingPreset(key: "preset_sony_venice",
                     template: "{cam}{roll}C{clip}_{yymmdd}{postfix}",
                     clipDigits: 3, rollDigits: 3),
        NamingPreset(key: "preset_sony_alpha",
                     template: "C{clip}",
                     clipDigits: 4, rollDigits: nil),
        NamingPreset(key: "preset_bmd",
                     template: "{cam}{roll}_{mmdd}{hhmm}_C{clip}",
                     clipDigits: 3, rollDigits: 3),
        NamingPreset(key: "preset_canon",
                     template: "{cam}_{roll}C{clip}X{yymmdd}_{hhmmss}{postfix}_CANON",
                     clipDigits: 3, rollDigits: 4),
    ]
}
