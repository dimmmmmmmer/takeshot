import Foundation

/// The persisted shape of `CaptureSettings`, written down.
///
/// `CaptureSettings` IS the on-disk format: it is JSON-encoded into
/// `UserDefaults` under one key, and a change to the encoded shape does not
/// fail — it silently resets every existing operator's settings on update.
/// Destination folder, naming template, calibrated assist thresholds, the
/// taught REC references: gone, on a shooting day, with no error anywhere.
///
/// So the format is pinned here as DATA rather than left implicit in the
/// declaration order of a Swift struct. Nothing in this file names a Swift
/// property path, deliberately: the pin has to survive any rearrangement of the
/// type, and a fixture written in terms of `settings.foo` would have to be
/// edited by the very refactor it exists to check.
///
/// Two consumers depend on this, not one:
///
/// 1. **Persistence.** `CaptureSettings.save(to:)` / `.loaded(from:)`.
/// 2. **The diagnostics bundle.** `DiagnosticsRedaction.settings(_:)` walks the
///    encoded JSON as a FLAT map and drops secrets by matching the key name —
///    that is how `remotePIN` is kept out of a bundle without anyone having to
///    remember it. Nest that key one level down and the filter stops seeing it.
///    Flatness is a privacy contract here, not a style choice.
enum SettingsFormatFixture {
    /// The defaults key the blob is stored under.
    static let defaultsKey = "TakeShot.CaptureSettings"

    /// Every key the current format has, sorted. 84 of them.
    ///
    /// Adding a key here is how a new setting is declared to exist; a key that
    /// disappears from this list is a setting that every existing operator
    /// loses. Neither should ever happen by accident, which is the whole point
    /// of writing them out.
    static let allKeys: [String] = [
        "accentHex", "appBackgroundHex", "appLanguage", "appearance",
        "audioChannelMask", "audioInputDeviceUID", "cameraLabel",
        "captureBitDepth", "chromaKeyBackground", "chromaKeyBackgroundHex",
        "chromaKeyBackgroundImagePath", "chromaKeyColorHex",
        "chromaKeyPlateFit", "chromaKeyPlateOffsetX", "chromaKeyPlateOffsetY",
        "chromaKeyPlateScale", "chromaKeySoftness", "chromaKeySpill",
        "chromaKeyTolerance", "clipPadWidth", "codec", "colorTagPreset",
        "compareDifferenceGain", "compareMode", "dailiesBurnClipName",
        "dailiesBurnDate", "dailiesBurnProject", "dailiesBurnTimecode",
        "dailiesCustomText", "dailiesDestinationPath", "defaultMarkerColor",
        "desqueezeFactor", "destinationPath", "detectionMode",
        "forcedInputMode", "forcedInputRGB", "framelineRatio", "hdrMode",
        "keepInMenuBar", "legendPlacement", "legendSize", "ltcChannel",
        "lutFileName", "lutIntensity", "lutPreviewEnabled", "lutRecordEnabled",
        "monitorDeviceID", "monitorDimmed", "monitorEnabled", "monitorMuted",
        "monitorVolume", "namingTemplate", "ndiEnabled", "ndiSourceName",
        "offerMountedCards", "offloadDestinationPaths", "peakingColor",
        "peakingIntensity", "playbackAudioDeviceUID", "playerBackgroundHex",
        "postfix", "preRollFrames", "preRollSeconds", "projectName",
        "r3dApplyCameraLUT", "r3dDecodeScale", "remoteEnabled", "remotePIN",
        "remotePort", "safeActionPercent", "safeAreasOn", "safeTitlePercent",
        "schemaVersion", "startDebounceFrames", "stopDebounceFrames",
        "tenBitCapture", "timecodeSource", "videoLevels", "visualRecCenterX",
        "visualRecCenterY", "visualRecIdle", "visualRecMargin",
        "visualRecRolling", "visualRecSize",
    ]

    /// The keys a DEFAULT `CaptureSettings()` writes — the non-Optional ones,
    /// and only those.
    ///
    /// Two contracts in one list. Every OTHER field is Optional, which is what
    /// lets an older blob decode at all (a synthesized decoder does not fall
    /// back to a property's default, so a non-Optional field added today would
    /// make every settings blob written before today undecodable). And a nil
    /// Optional is OMITTED rather than written as null — `encodeIfPresent` —
    /// so a default install stores eight keys, not eighty-four.
    static let alwaysWrittenKeys: [String] = [
        "cameraLabel", "codec", "destinationPath", "detectionMode",
        "namingTemplate", "projectName", "startDebounceFrames",
        "stopDebounceFrames",
    ]

    /// A settings blob as this build writes it, with every key present and a
    /// DISTINCT value in each.
    ///
    /// Distinct on purpose: a re-encode of this compared value by value cannot
    /// then be satisfied by two fields that have quietly swapped keys, which is
    /// the one silent failure a key-set check alone would let through.
    ///
    /// `schemaVersion` is the current one, so the migration chain is a no-op on
    /// it and a load is a pure round trip. The older shapes are covered by
    /// `ModelSettingsMigrationTests`.
    static let populatedJSON = """
        {
          "accentHex": "#FF8800",
          "appBackgroundHex": "#131415",
          "appLanguage": "ru",
          "appearance": "dark",
          "audioChannelMask": 5,
          "audioInputDeviceUID": "com.focusrite.usb:Scarlett18i20",
          "cameraLabel": "B",
          "captureBitDepth": "12",
          "chromaKeyBackground": "solid",
          "chromaKeyBackgroundHex": "#0A0B0C",
          "chromaKeyBackgroundImagePath": "/Volumes/SHOOT01/plates/bg01.png",
          "chromaKeyColorHex": "#00B140",
          "chromaKeyPlateFit": "fill",
          "chromaKeyPlateOffsetX": 0.07,
          "chromaKeyPlateOffsetY": -0.03,
          "chromaKeyPlateScale": 1.15,
          "chromaKeySoftness": 0.22,
          "chromaKeySpill": 0.44,
          "chromaKeyTolerance": 0.31,
          "clipPadWidth": 3,
          "codec": "ProRes 4444",
          "colorTagPreset": "2020",
          "compareDifferenceGain": 4,
          "compareMode": "difference",
          "dailiesBurnClipName": true,
          "dailiesBurnDate": true,
          "dailiesBurnProject": false,
          "dailiesBurnTimecode": false,
          "dailiesCustomText": "INTERNAL - NOT FOR DISTRIBUTION",
          "dailiesDestinationPath": "/Volumes/SHOOT01/Dailies",
          "defaultMarkerColor": "cyan",
          "desqueezeFactor": 1.33,
          "destinationPath": "/Volumes/SHOOT01/TakeShot",
          "detectionMode": "auto",
          "forcedInputMode": "1080p25",
          "forcedInputRGB": true,
          "framelineRatio": 2.39,
          "hdrMode": "off",
          "keepInMenuBar": true,
          "legendPlacement": "top",
          "legendSize": "l",
          "ltcChannel": 3,
          "lutFileName": "ShowLUT_v4.cube",
          "lutIntensity": 0.65,
          "lutPreviewEnabled": true,
          "lutRecordEnabled": false,
          "monitorDeviceID": "UltraStudio 4K Mini (2)",
          "monitorDimmed": true,
          "monitorEnabled": false,
          "monitorMuted": false,
          "monitorVolume": 0.42,
          "namingTemplate": "{prefix}_{cam}{roll}C{clip}_{postfix}",
          "ndiEnabled": true,
          "ndiSourceName": "Nightfall B",
          "offerMountedCards": false,
          "offloadDestinationPaths": ["/Volumes/BACKUP_A", "/Volumes/BACKUP_B"],
          "peakingColor": "blue",
          "peakingIntensity": 18.5,
          "playbackAudioDeviceUID": "AppleHDAEngineOutput:1B,0,1,1:0",
          "playerBackgroundHex": "#101112",
          "postfix": "MAIN",
          "preRollFrames": 12,
          "preRollSeconds": 0.75,
          "projectName": "Nightfall",
          "r3dApplyCameraLUT": true,
          "r3dDecodeScale": "half",
          "remoteEnabled": true,
          "remotePIN": "4718",
          "remotePort": 9123,
          "safeActionPercent": 91.5,
          "safeAreasOn": true,
          "safeTitlePercent": 88.5,
          "schemaVersion": 3,
          "startDebounceFrames": 4,
          "stopDebounceFrames": 6,
          "tenBitCapture": false,
          "timecodeSource": "ltc",
          "videoLevels": "limited",
          "visualRecCenterX": 0.62,
          "visualRecCenterY": 0.18,
          "visualRecIdle": "aWRsZS1yZWZlcmVuY2U=",
          "visualRecMargin": 0.55,
          "visualRecRolling": "cm9sbGluZy1yZWZlcmVuY2U=",
          "visualRecSize": 0.09
        }
        """

    static var populatedData: Data { Data(populatedJSON.utf8) }

    /// A JSON object as sorted `key = value` lines.
    ///
    /// Compared as text rather than as `NSDictionary` so a failure names the
    /// field that moved instead of printing two eighty-four-entry dictionaries
    /// and leaving the reader to diff them.
    static func lines(of object: [String: Any]) -> [String] {
        object.keys.sorted().map { "\($0) = \(describe(object[$0] ?? "<missing>"))" }
    }

    /// Parsed into a plain dictionary, or an empty one if it is not an object.
    static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// One JSON value as text. Booleans are told apart from 0 and 1 explicitly —
    /// `JSONSerialization` hands both back as `NSNumber`, and "monitorEnabled =
    /// 0" would read as a level rather than a switch.
    private static func describe(_ value: Any) -> String {
        switch value {
        case let string as String: return "\"\(string)\""
        case let array as [Any]: return "[" + array.map(describe).joined(separator: ", ") + "]"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case is NSNull: return "null"
        default: return "<\(type(of: value))>"
        }
    }
}
