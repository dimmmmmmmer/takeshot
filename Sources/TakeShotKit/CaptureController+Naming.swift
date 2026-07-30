import AppKit
import CaptureCore
import Foundation
import SwiftUI

/// The naming fields under the player: clip number and its padding, presets,
/// and the roll/camera steppers.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. The collision warning
/// these feed lives in `+Library` with the folder scan that detects it.
extension CaptureController {
    /// The record root folder (for the "open folder" button).
    var destinationRoot: URL {
        URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
    }

    /// Clip number with the current padding (for the field and name preview).
    var clipDisplay: String {
        String(format: "%0\(settings.clipPadWidthEffective)d", nextTakeNumber)
    }

    /// Apply the clip text typed into the field: digits → number,
    /// the count of typed digits (with leading zeros) → filename padding.
    func commitClipText(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        settings.clipPadWidth = min(4, max(2, digits.count))
        nextTakeNumber = min(9999, max(0, Int(digits) ?? nextTakeNumber))
    }

    /// Apply a naming preset: template, clip width, and roll width.
    func applyNamingPreset(_ preset: NamingPreset) {
        settings.namingTemplate = preset.template
        settings.clipPadWidth = preset.clipDigits
        if let rollDigits = preset.rollDigits,
           let range = roll.range(of: "[0-9]+$", options: .regularExpression),
           let number = Int(roll[range]) {
            roll = roll[..<range.lowerBound] + String(format: "%0\(rollDigits)d", number)
        }
    }

    // MARK: - naming-field steppers

    func stepRoll(_ delta: Int) {
        roll = FieldStepper.stepTrailingNumber(roll, by: delta)
    }

    func stepCamera(_ delta: Int) {
        settings.cameraLabel = FieldStepper.stepLetter(settings.cameraLabel, by: delta)
    }
}

extension CaptureController {
    /// The next clip number — after the max in the current roll. Lives with
    /// the naming logic: the clip number is a naming input, the library scan
    /// merely triggers the recount.
    func continueClipNumbering() {
        let maxClip = takes.filter { $0.roll == roll }.map(\.takeNumber).max() ?? 0
        nextTakeNumber = maxClip + 1
    }
}
