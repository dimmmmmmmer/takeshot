import CaptureCore
import SwiftUI

/// The pre-roll rows in Settings: the unit the operator wants to type in, the
/// field itself, and the line that reads the value back in both units.
///
/// The unit is a choice about the FIELD and nothing else — the setting stored
/// is a frame count either way (see `CaptureController+PreRoll`), so this is
/// not the kind of preference "Settings the app deliberately does not offer" is
/// about. Nothing here asserts a measurement; the one measurement involved, the
/// signal's frame rate, is what the conversion reads.
struct PreRollRows: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker(L("pre_roll_unit"), selection: Binding(
            get: { controller.preRollUnit },
            set: { controller.preRollUnit = $0 })) {
            Text(L("pre_roll_unit_frames")).tag(PreRollUnit.frames)
            Text(L("pre_roll_unit_seconds")).tag(PreRollUnit.seconds)
        }
        switch controller.preRollUnit {
        case .frames:
            FrameCountField(label: L("pre_roll_frames"), value: Binding(
                get: { controller.preRollFrames },
                set: { controller.preRollFrames = $0 }),
                range: CaptureSignalSettings.preRollFrameRange)
        case .seconds:
            preRollSecondsRow
        }
        LabeledContent(L("pre_roll_reading")) {
            Text(controller.preRollReading)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Seconds typed, frames stepped.
    ///
    /// The stepper moves the FRAME count by one because that is the finest step
    /// the setting has — a seconds stepper would either move by less than a
    /// frame (and change nothing) or by more than one (and skip values the
    /// operator can reach by typing). Both controls write through
    /// `controller.preRollFrames`, so the range is applied once, by the model.
    private var preRollSecondsRow: some View {
        LabeledContent(L("pre_roll_seconds")) {
            HStack(spacing: 6) {
                TextField("", value: Binding(
                    get: { controller.preRollSecondsEntry },
                    set: { controller.preRollSecondsEntry = $0 }),
                    format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: Binding(
                    get: { controller.preRollFrames },
                    set: { controller.preRollFrames = $0 }),
                    in: CaptureSignalSettings.preRollFrameRange)
                    .labelsHidden()
            }
        }
    }
}
