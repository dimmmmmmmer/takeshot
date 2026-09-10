import CaptureCore
import SwiftUI

/// **The encoder's dials**, folded away until they are wanted (owner: "у
/// энкодера там профиль выбрать типа, абр цбр, кейфреймы б фреймы, в общем что
/// посчитаешь нужным для кастомизации но чтобы не перегружать пользователя").
///
/// Five, and every one of them defaulted to what this app has always streamed,
/// so an operator who never opens this sees no change and a stream set up
/// before they existed is byte-for-byte the stream it was.
///
/// **The colour is deliberately not here.** The tags follow the signal — the
/// display buffer's own primaries, transfer and matrix, out of the one table
/// that decides what any tag in this app says — and a hand-set primary on the
/// wire is a picture that is wrong at the far end with nothing on this one to
/// say so. It is the one setting where "let the operator choose" is the worse
/// answer.
///
/// A disclosure for the reason the dailies' appearance dials are one: these
/// are set once for a venue, and the pane above them is read on a cart.
struct SRTEncoderRows: View {
    @ObservedObject var controller: CaptureController

    /// **Open, not behind a disclosure** (owner: "настройки энкодера можно
    /// нормально повесить без выпадающего списка… просто чтоб сразу они были
    /// видны"). They were folded away because the section was long; the Start
    /// control that used to sit above them has moved onto the status row, and
    /// the height it gave back is what pays for these being visible.
    var body: some View {
        Group {
            Text(L("srt_encoder_section"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
                Picker(L("codec"), selection: Binding(
                    get: { controller.settings.srt.codecEffective },
                    set: { controller.settings.srt.codec =
                        $0 == .h264 ? nil : $0.rawValue })) {
                    ForEach(SRTVideoCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .help(L("srt_codec_help"))
                // **The chosen CODEC's own family**, not all five: H.264 is
                // Baseline/Main/High and HEVC is Main/Main 10/Main 4:2:2 10.
                // One list for both offered "High" over an HEVC stream, which
                // is not a profile HEVC has (owner: "в энкодере для hevc что
                // значит profile high вообще?").
                Picker(L("srt_profile"), selection: Binding(
                    get: {
                        controller.settings.srt.profileEffective
                            .resolved(for: controller.settings.srt.codecEffective)
                    },
                    set: { controller.settings.srt.profile = $0.rawValue })) {
                    ForEach(SRTEncoderProfile.offered(
                        for: controller.settings.srt.codecEffective)) { profile in
                        Text(L(profile.labelKey)).tag(profile)
                    }
                }
                .help(L("srt_profile_help"))
                Picker(L("srt_rate_control"), selection: Binding(
                    get: { controller.settings.srt.rateControlEffective },
                    set: { controller.settings.srt.rateControl =
                        $0 == .average ? nil : $0.rawValue })) {
                    ForEach(SRTRateControl.allCases) { mode in
                        Text(L(mode.labelKey)).tag(mode)
                    }
                }
                .help(L("srt_rate_help"))
                keyframeRow
                Toggle(L("srt_b_frames"), isOn: Binding(
                    get: { controller.settings.srt.bFramesEffective },
                    set: { controller.settings.srt.bFrames = $0 ? true : nil }))
                    .toggleStyle(.checkbox)
                    .help(L("srt_b_frames_help"))
            }
        }
    }

    /// Seconds between keyframes: a stepper rather than a free number, because
    /// the useful range is small and every value in it is a second a receiver
    /// may have to wait.
    private var keyframeRow: some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Text(L("srt_keyframes")).fixedSize()
            Spacer(minLength: 4)
            Stepper(value: Binding(
                get: { controller.settings.srt.keyframeSecondsEffective },
                set: { controller.settings.srt.keyframeSeconds =
                    $0 == 1 ? nil : $0 }), in: 1...10) {
                Text(L("srt_keyframes_value",
                       controller.settings.srt.keyframeSecondsEffective))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .help(L("srt_keyframes_help"))
    }
}
