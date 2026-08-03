import CaptureCore
import SwiftUI

/// The two R3D playback rows, in their own file per the convention that a
/// settings section is hostable on its own by the render tests.
///
/// Both rows exist because R3D is the first format in this app whose decoder had
/// real choices to make. The picture the operator judges cannot depend on a
/// decision nobody can see: the scale row is the speed/detail trade a
/// video-assist player has to make on an 8K clip, and the LUT row is the
/// difference between a reference viewer and someone's look. Neither is offered
/// as a colour-space choice — a viewer that can be switched to log is a viewer
/// that will be found in log by the next person to use it.
struct R3DSettingsSection: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Section(L("settings_r3d")) {
            Picker(L("r3d_decode_scale"), selection: Binding(
                get: { controller.settings.r3dDecodeScaleEffective },
                set: {
                    // nil, not "auto": an untouched install writes no key, so a
                    // later change of default reaches it.
                    controller.settings.r3dDecodeScale =
                        $0 == .auto ? nil : $0.rawValue
                })) {
                Text(L("r3d_scale_auto")).tag(R3DDecodeScale.auto)
                Text(L("r3d_scale_full")).tag(R3DDecodeScale.full)
                Text(L("r3d_scale_half")).tag(R3DDecodeScale.half)
                Text(L("r3d_scale_quarter")).tag(R3DDecodeScale.quarter)
                Text(L("r3d_scale_eighth")).tag(R3DDecodeScale.eighth)
            }
            Toggle(L("r3d_camera_lut"), isOn: Binding(
                get: { controller.settings.r3dApplyCameraLUT ?? false },
                set: { controller.settings.r3dApplyCameraLUT = $0 ? true : nil }))
            Text(L("r3d_color_legend"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
