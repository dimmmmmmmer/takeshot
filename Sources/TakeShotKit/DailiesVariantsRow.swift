import CaptureCore
import SwiftUI

/// **The extra versions of the same day** (owner: "и да, очередь из нескольких
/// вариантов дейликов будет супер").
///
/// Under the output row rather than replacing it, and that is the design
/// rather than a compromise: the row above IS the daily — the one every unit
/// makes — and these are the copies that go somewhere else. An operator who
/// never opens this list sees the sheet they have always seen, and a run with
/// an empty list is the run this app has always made.
///
/// Each row is the three things that make a review copy what it is: how big,
/// in what codec, and what to call it. The suffix is not decoration — two
/// versions of one take land in one folder, and without different names the
/// second arrives as `_2` beside the first with nothing to say which is which.
struct DailiesVariantsRow: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack(spacing: OffloadChrome.rowSpacing) {
                Text(L("dailies_variants")).offloadText(.body).fixedSize()
                Button {
                    model.addVariant()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.hoverPlain)
                .disabled(!controller.canAddDailiesVariant)
                .help(L("dailies_variants_add_help"))
                Spacer(minLength: 4)
            }
            ForEach($model.extraVariants) { $variant in
                HStack(spacing: OffloadChrome.rowSpacing) {
                    Picker("", selection: $variant.resolution) {
                        ForEach(DailiesResolution.allCases) { size in
                            Text(size == .source
                                 ? L("dailies_resolution_source") : size.label)
                                .tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $variant.codec) {
                        ForEach(CaptureCodec.dailiesChoices) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // The same filtered field the name row uses: what is typed
                    // here reaches `appendingPathComponent`.
                    NameTextField(field: .prefix, text: $variant.suffix,
                                  placeholder: L("dailies_name_suffix"))
                        .frame(width: DailiesOutputSection.nameFieldWidth)
                    Button {
                        model.removeVariant(variant.id)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.hoverPlain)
                    .disabled(controller.isDailiesRunning)
                    Spacer(minLength: 4)
                }
            }
            // What the extras cost, stated where they are asked for: every one
            // is another decode of every take, and that is the number an
            // operator is deciding about at 2 a.m.
            if !model.extraVariants.isEmpty {
                Text(L("dailies_variants_passes",
                       model.extraVariants.count + 1))
                    .offloadText(.caption)
            }
        }
        .disabled(controller.isDailiesRunning)
    }
}
