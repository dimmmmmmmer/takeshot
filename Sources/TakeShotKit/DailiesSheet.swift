import AppKit
import CaptureCore
import SwiftUI

/// The dailies sheet: the batch, the burn-in switches, one destination, Start.
///
/// Set in the offload sheets' type family (`offloadText`/`OffloadChrome`) on
/// purpose — the two sheets are siblings in the same corner of the app, and a
/// second type zoo is how the first one grew. Like the offload sheet it can be
/// closed over a running queue; the takes-panel strip reports on the run while
/// the sheet is away (see `DailiesStatusStrip`).
struct DailiesSheet: View {
    @ObservedObject var model: DailiesQueueModel
    @Environment(\.dismiss) private var dismiss

    /// **Wide, and no longer scrolling.**
    ///
    /// It was 470 with everything in one column and a `ScrollView` around it,
    /// and it had outgrown that: measured, the idle sheet came to 558pt, a run
    /// 660 and a finished run with fourteen failures 841 — against an app whose
    /// window may be 620 tall. So a scrollbar appeared on a sheet that looks
    /// like it fits (owner: "почему-то это окошко скролл еще выдает"), and the
    /// codec and file-name rows this sheet has since grown would each have
    /// added another 36.
    ///
    /// The width was the unused dimension. The switches take one column and
    /// the preview stands beside them, which halves the tall part and puts the
    /// picture next to the controls that change it. Measured after: 457 idle,
    /// and every state inside the budget with the scroll view gone.
    ///
    /// 760 = two burn columns of `DailiesBurninSection.columnWidth`, the gap
    /// between them, the sheet's own 20pt margins and the inset each tab face
    /// applies (`tabInset`). The column is 320 because the widest Russian burn
    /// label is 138pt and the place picker is 150
    /// (`aBurnRowFitsTheSheetInBothLanguages`).
    ///
    /// It was 680 with the switches in ONE column and the preview beside them.
    /// The rows moved into two columns so the picture could go underneath them
    /// (see `burninsTab`), and two of them plus the tab's inset is what the
    /// extra 80 pays for.
    static let width: CGFloat = 760

    /// What each tab face keeps between itself and the `TabView`'s own border.
    ///
    /// A `TabView` insets its content by about 4pt, which is enough not to
    /// clip and not enough to look deliberate: every control in both faces sat
    /// against the box's edge (owner: "какие-то рамки к которым вплотную юи
    /// стоит, странно выглядит"). Both faces apply this, so neither can drift.
    static let tabInset: CGFloat = 12

    /// The sheet's own margin, around everything.
    static let margin: CGFloat = 16

    /// What the tabbed area gets. Fixed rather than fitted: the two faces are
    /// different heights, and a sheet that resized as the operator switched
    /// tabs would jump under the pointer. Set by the taller face (the
    /// burn-ins, with the appearance dials open) plus the room the file lists
    /// need for a few rows before they scroll.
    ///
    /// It grew with the restack: the burn-ins face is now the switches ABOVE
    /// the picture rather than beside it, so its height is the sum of the two
    /// where it used to be the larger. `theDailiesSheetFitsTheWindowInEveryState`
    /// is what holds the total against the window.
    static let tabHeight: CGFloat = 412

    var body: some View {
        VStack(spacing: 0) {
            content.padding(Self.margin)
            Divider()
            footer
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 14)
        }
        .frame(width: Self.width)
    }

    /// The sheet without its fixed frame — what the render tests measure
    /// (a pinned frame reports the pin, not what the content needed).
    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.sectionSpacing) {
            // **The batch reads on the title's own line.** It was a caption
            // under it, and those two lines plus the gap between them were
            // 29pt of the sheet's height — height the picture underneath
            // wanted more than the heading did. They are one sentence about
            // one batch and they sit as one.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("dailies_title"))
                    .offloadText(.title)
                Spacer(minLength: 4)
                Text(L("dailies_batch",
                       localizedCount(model.itemCount, .take),
                       model.codec.rawValue))
                    .offloadText(.caption)
                    .fixedSize()
            }
            // **Two tabs, and the reason is height.** The burn-ins and the
            // files are two questions about one batch, and putting both on one
            // face put the sheet past the window it has to fit — the folder
            // lists alone are 160pt (owner asked for several sources and
            // several destinations, "как в оффлоаде"). Tabbed, each face is
            // measured on its own and neither can push the other out.
            TabView {
                burninsTab
                    .tabItem { Text(L("dailies_tab_burnins")) }
                DailiesFilesTab(model: model)
                    .tabItem { Text(L("dailies_tab_files")) }
            }
            .frame(height: Self.tabHeight)
        }
    }

    /// **The settings above, the picture centred underneath them.**
    ///
    /// It was two columns — switches on the left, whatever the batch had to
    /// say on the right — which is what first got this sheet's height under
    /// the window's. The arrangement read as unfinished: the preview was a
    /// small panel wedged against the tab's own border, beside the controls it
    /// previews rather than under them (owner: "на первой странице превью
    /// плейбека должно по центру стоять снизу а параметры над окном этим
    /// аккуратно").
    ///
    /// Stacked, the picture is what the eye lands on and it can be bigger —
    /// which is what retired the separate fullscreen preview window the owner
    /// asked for when it was small ("можно будет вырезать функцию фул скрин
    /// превью"). The switches pay for it by going into two columns; the height
    /// that buys back is what keeps the sheet inside the window.
    /// **One definition, two ways of being asked about.**
    ///
    /// `stretched` is the only difference between what the tab mounts and what
    /// the suite measures. The tab's copy fills `tabHeight` and pushes the
    /// picture to the bottom of it; a stretched view reports the PROPOSAL it
    /// was handed rather than what it needed, so the measurement that says
    /// whether the face is being clipped has to ask the unstretched one. Two
    /// spellings of this face would be two things to keep in step.
    @ViewBuilder func burninsFace(stretched: Bool) -> some View {
        VStack(spacing: OffloadChrome.sectionSpacing) {
            DailiesBurninSection(model: model)
            if stretched { Spacer(minLength: 0) }
            stateColumn
        }
        .padding(Self.tabInset)
        .frame(maxWidth: .infinity,
               maxHeight: stretched ? .infinity : nil, alignment: .top)
    }

    private var burninsTab: some View { burninsFace(stretched: true) }

    /// **One slot, three things to say, never two at once.**
    ///
    /// The preview, the live progress and the finished report used to be
    /// stacked under each other, so their heights ADDED: a fourteen-take
    /// batch that all failed came to 646pt against a window that may be 620,
    /// which is the last thing keeping a scrollbar on this sheet. They are
    /// three answers to one question — what is happening with this batch —
    /// and only one of them is ever the current answer, so they take turns in
    /// one column and the sheet's height stops depending on the run.
    ///
    /// The order is the run's own: a report is the newest news, then a run in
    /// flight, then the arrangement you are still setting up.
    @ViewBuilder private var stateColumn: some View {
        if let report = model.report {
            DailiesResultPanel(report: report)
        } else if let progress = model.progress {
            DailiesProgressPanel(progress: progress,
                                 onSkip: { model.skipCurrentItem() })
        } else {
            // **What it will look like**, drawn by the code that burns the
            // frame (owner: "а главное визуализации").
            DailiesBurninPreview(model: model, still: model.previewStill)
        }
    }

    // MARK: - footer

    /// Close stays live over a running queue and says so — the run continues
    /// and the takes panel reports on it (the offload sheet's contract).
    private var footer: some View {
        DailiesSheetFooter(model: model) { dismiss() }
    }
}

/// The burn-in switches.
///
/// A view of its own rather than a property of the sheet, and the reason is the
/// same one `OffloadSheetFooter` states: it reads the enabling rule off the
/// controller, and an `@EnvironmentObject` is only bound when SwiftUI evaluates
/// the view — a property the render tests ask for directly is evaluated by the
/// test instead, with no environment at all.
struct DailiesBurninSection: View {
    /// The place picker's width. Fixed so the six rows line up, and named so
    /// the render test can ask whether the longest place name fits inside it —
    /// a menu Picker truncates rather than pushing wider, and the two names
    /// that would collide first are the two centre ones.
    static let pickerWidth: CGFloat = 150

    /// The switch column's width, and half of where the sheet's own comes
    /// from. Measured: the longest Russian label is "Проект · камера/ролл" at
    /// 138pt, plus a checkbox at 21 and the 150pt picker.
    static let columnWidth: CGFloat = 320

    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            Text(L("dailies_burn_section"))
                .offloadText(.section)
            // Each line with its own place. A toggle and a picker on one row,
            // because "is it on" and "where is it" are one decision about one
            // line and reading them apart is how an operator ends up with the
            // reel where the timecode should be.
            // **Two columns**, so the picture can stand under them rather
            // than beside them (see `DailiesSheet.burninsTab`). The split is
            // by KIND and not by count: the three lines the app writes itself
            // on the left, the two an operator sets on the right — the date
            // is a fact of the shoot and the custom line is a sentence they
            // type, and the text box belongs under the checkbox that arms it.
            HStack(alignment: .top, spacing: OffloadChrome.sectionSpacing) {
                VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
                    burnRow(L("dailies_burn_tc"), on: $model.burnTimecode,
                            at: $model.timecodePosition)
                    burnRow(L("dailies_burn_name"), on: $model.burnClipName,
                            at: $model.clipNamePosition)
                    burnRow(L("dailies_burn_project"), on: $model.burnProject,
                            at: $model.projectPosition)
                    // **The date is the app's own line too**, so it belongs on
                    // this side (owner: "перенесем рекординг дейт в левый
                    // столбик, чтоб аппеаренс не скрывался а лежал прям под
                    // кастом тайтлом – уравновесим столбики"). Four rows here
                    // against the custom line plus the appearance dials there
                    // is what makes the two columns the same height.
                    //
                    // It has a place of its own at all because it used to be
                    // joined onto the project line — four corners could not
                    // hold five facts — and that stopped being true when every
                    // line got a picker, leaving the date as the only fact
                    // that could not be moved and no way to say why (owner:
                    // "не оч понятно почему у рекординг дейт нельзя выбрать
                    // положение").
                    burnRow(L("dailies_burn_date"), on: $model.burnDate,
                            at: $model.datePosition)
                }
                .frame(width: Self.columnWidth)
                VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
                    // **The box IS the label** (owner: "тут вместо
                    // кастомлайна давай сразу бокс для подписи и поставим").
                    // The row used to read "Custom line" beside a checkbox
                    // with the field on a line of its own underneath — two
                    // rows to say one thing, and the words "Custom line" said
                    // nothing the empty box did not. The checkbox arms it, the
                    // box is what goes on the frame, and the place picker sits
                    // where every other line's does.
                    HStack(spacing: OffloadChrome.rowSpacing) {
                        Toggle("", isOn: $model.burnCustom)
                            .labelsHidden()
                            .accessibilityLabel(L("dailies_custom_placeholder"))
                        // Filtered rather than plain: it is burned into a
                        // frame, not into a file name, but a control that
                        // silently rewrites what was typed is the thing
                        // `NameTextField` exists to prevent — here it is only
                        // the placeholder and the alignment that differ.
                        TextField(L("dailies_custom_hint"), text: $model.customText)
                            .textFieldStyle(.roundedBorder)
                            // disabled(exception): about THIS row's own
                            // checkbox rather than about app state, exactly
                            // like the place pickers in `burnRow` — there is
                            // nothing to type into a line that is switched
                            // off. The app-state rule (a run is going) is
                            // named once for the whole section.
                            .disabled(!model.burnCustom)
                        positionPicker(at: $model.customPosition)
                            // disabled(exception): per-ROW, about this row's
                            // own checkbox — see `burnRow`, which states the
                            // same rule for the four lines above.
                            .disabled(!model.burnCustom)
                    }
                    // **Open, not folded away.** It was a `DisclosureGroup`,
                    // which is a second dropdown in a face that already has
                    // five, and it hid the two dials most likely to be wanted
                    // after a place is chosen. The date moving left is what
                    // made room for it (owner: "чтоб аппеаренс не скрывался а
                    // лежал прям под кастом тайтлом… избавимся от лишнего
                    // выпадающего списка, будет аккуратнее").
                    DailiesInkRows(model: model)
                }
                .frame(width: Self.columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toggleStyle(.checkbox)
        .disabled(controller.isDailiesRunning)
    }

    private func burnRow(_ title: String, on: Binding<Bool>,
                         at position: Binding<DailiesBurninPosition>) -> some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Toggle(title, isOn: on)
            Spacer(minLength: 4)
            positionPicker(at: position)
                // disabled(exception): per-ROW, and about THIS row's own
                // toggle rather than about app state — a place is only worth
                // choosing for a line that is being burned. The condition is
                // the argument the row was handed, and `burnRow` is the single
                // definition all four rows go through, so there is no second
                // surface that could spell it differently. The whole section
                // is disabled from the controller while a run is going, which
                // is the app-state rule and is named once, below.
                .disabled(!on.wrappedValue)
        }
    }

    private func positionPicker(
        at position: Binding<DailiesBurninPosition>) -> some View {
        Picker("", selection: position) {
            ForEach(DailiesBurninPosition.allCases, id: \.self) { place in
                Text(L(place.labelKey)).tag(place)
            }
        }
        .labelsHidden()
        .frame(width: Self.pickerWidth)
    }
}

extension DailiesBurninPosition {
    /// The strings key for this place, in the picker.
    ///
    /// The keys are LITERALS and not `"dailies_position_" + rawValue`, for the
    /// reason `CountedNoun` spells out: a key the sources never write is a key
    /// `everyKeyWrittenAsALiteralIsInBothStringsFiles` cannot check and
    /// `everyKeyInTheTableIsReachedFromTheCode` reads as dead. Written out,
    /// both walks see all six — and `everyBurninPositionHasWordsInBothLanguages`
    /// closes the loop by asking this property for each case.
    var labelKey: String {
        switch self {
        case .topLeft: return "dailies_position_topLeft"
        case .topCenter: return "dailies_position_topCenter"
        case .topRight: return "dailies_position_topRight"
        case .center: return "dailies_position_center"
        case .bottomLeft: return "dailies_position_bottomLeft"
        case .bottomCenter: return "dailies_position_bottomCenter"
        case .bottomRight: return "dailies_position_bottomRight"
        }
    }
}

/// **The burn-ins as they will be**, rendered by the same code that burns the
/// frame — see `DailiesOverlay.previewImage`.
///
/// A rendering and not a mock-up on purpose: a preview drawn by different code
/// is a preview that can be wrong, and the one question it exists to answer is
/// whether the real thing will look like this.
struct DailiesBurninPreview: View {
    @ObservedObject var model: DailiesQueueModel
    /// A real frame from the footage to lay the strips over, or nil for the
    /// flat grey. Taken IN rather than read from the environment: `picture`
    /// below is a computed property, a render test asks for it directly, and
    /// an `@EnvironmentObject` reached that way traps
    /// (`CaptureController.dailiesPreviewStill`).
    var still: CGImage?

    /// 16:9 at a size that shows the arrangement without taking the sheet
    /// over.
    ///
    /// **This is a frame and not a maximum.** It used to be `maxWidth:
    /// .infinity` with the aspect ratio doing the rest, so inside the sheet's
    /// 430pt of content the preview laid out at 430×241.875 — 62 points taller
    /// than the size documented here, and a fractional height on top of it.
    /// That is what put a scrollbar on a sheet that looks like it fits (owner:
    /// "почему-то это окошко скролл еще выдает"), and it was showing a 320px
    /// bitmap at 430pt besides.
    ///
    /// It grew from 288×162 with the restack: the picture stands under the
    /// switches now instead of beside them, so its width is no longer half the
    /// sheet's — and it is the ONLY preview there is, the separate fullscreen
    /// window having gone with the same change. Every point of it is bought
    /// from somewhere: the heading and the batch line share a row, the sheet's
    /// margin came down to 16, and the burn switches went into two columns.
    static let size = CGSize(width: 368, height: 207)

    /// The bitmap is rendered at twice the size it is shown at, for a reason
    /// beyond sharpness: the strips are 5% of the frame's height but never
    /// less than 14 points (`DailiesStripMetrics`), and 5% of 180 is 9 — so at
    /// the display size the floor binds and the plates come out 7.8% of the
    /// frame, half again as thick as the daily will actually carry. At 360 the
    /// floor does not bind and the preview shows the real proportion, which is
    /// the one question it exists to answer.
    static let raster: CGFloat = 2

    /// **The picture, and nothing under it.**
    ///
    /// The example file name used to be here, on the argument that the picture
    /// and the name are both "what am I about to make". It is under the PREFIX
    /// AND SUFFIX FIELDS now, on the other face — which is where the operator
    /// types the two ends it is made of, so the example changes under the
    /// control that changes it. What it bought this face is 22 points, and
    /// this face spends every point it has on the picture.
    var body: some View { picture }

    /// The rendered frame alone, without the name example under it —
    /// internal so `thePreviewKeepsTheSizeItDeclares` can measure the thing
    /// whose size is the rule.
    var picture: some View {
        ZStack {
            if let image = DailiesOverlay.previewImage(
                size: CGSize(width: Self.size.width * Self.raster,
                             height: Self.size.height * Self.raster),
                texts: texts,
                background: CGColor(gray: 0.22, alpha: 1),
                backgroundImage: still) {
                Image(decorative: image, scale: Self.raster)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(L("dailies_preview_help"))
        // No click-to-enlarge, and no window behind it. The picture was 288pt
        // wide beside the switches and a separate frame-size window was the
        // answer to that; standing under them it is the size it needed to be
        // in the first place (owner: "можно будет вырезать функцию фул скрин
        // превью").
        .help(L("dailies_preview_help"))
    }

    /// A sample take's facts, so the preview has something to place. The
    /// operator's own custom line and toggles are real; the clip name and the
    /// project line are examples, because a queue may be empty when the
    /// arrangement is being set up.
    private var texts: DailiesOverlay.Texts {
        model.burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/"), outputName: "",
            // The project line is the project NAME and nothing else — the
            // roll is in the file's own name and was taken off this line
            // (owner: "из места где проект убери подпись ролла"). The sample
            // still carried it, so the preview promised a format the burn
            // does not produce (owner: "проджект все еще почему то у себя
            // ролл пишет через точку").
            clipName: "A001C001", projectLine: "PROJECT",
            dateText: "12.07.26"))
    }
}

/// **What the batch will produce**: the codec, and the two ends of the name.
///
/// One row rather than a section of its own — these are two questions about
/// the same output, and the answer to both is previewed beside the picture
/// (see `DailiesBurninPreview`).
struct DailiesOutputSection: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController

    /// Each end of the name gets the same box, so "prefix" and "suffix" read
    /// as one control split in two rather than two unrelated fields.
    static let nameFieldWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack(spacing: OffloadChrome.rowSpacing) {
                Text(L("codec")).offloadText(.body).fixedSize()
                Picker("", selection: $model.codec) {
                    // The curated list, not every codec the app can record:
                    // a daily is a review copy (see `dailiesChoices`).
                    ForEach(CaptureCodec.dailiesChoices) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
            }
            HStack(spacing: OffloadChrome.rowSpacing) {
                Text(L("dailies_name_label")).offloadText(.body).fixedSize()
                // Filtered fields: what is typed here reaches
                // `appendingPathComponent`, and `NameField.prefix` is the rule
                // for what a path component may hold. A bare `TextField` bound
                // to a file-name value is a `ViewFieldRuleTests` failure for
                // exactly this reason.
                NameTextField(field: .prefix, text: $model.namePrefix,
                              placeholder: L("dailies_name_prefix"))
                    .frame(width: Self.nameFieldWidth)
                // The take's own name, which is what sits between the two
                // ends. Named `<FileName>` rather than `<takes>` (owner) — it
                // is one file's name, and the panel's title is a different
                // word doing a different job.
                Text(verbatim: "<FileName>")
                    .offloadText(.caption)
                    .fixedSize()
                NameTextField(field: .prefix, text: $model.nameSuffix,
                              placeholder: L("dailies_name_suffix"))
                    .frame(width: Self.nameFieldWidth)
                Spacer(minLength: 4)
            }
            // **What those two ends make, under the fields that set them.**
            // It used to sit under the burn-in preview on the other face, so
            // the example was a tab away from the controls that change it —
            // and the picture's face needed the height for the picture.
            Text(L("dailies_name_example",
                   model.outputName(for: "A001C001")
                       + "." + model.codec.dailiesFileExtension))
                .offloadText(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .disabled(controller.isDailiesRunning)
    }
}

/// The sheet's action bar. Its own view for the reason above — Stop and Start
/// both ask the controller for their rule — and, like the offload sheet's
/// footer, it takes its dismissal in rather than reading the environment: a
/// footer measured on its own in a render test has no sheet to dismiss.
struct DailiesSheetFooter: View {
    @ObservedObject var model: DailiesQueueModel
    @EnvironmentObject private var controller: CaptureController
    let dismiss: () -> Void

    var body: some View {
        HStack {
            if model.isRunning {
                Button(L("dailies_stop")) { model.cancel() }
                    .disabled(!controller.canSteerDailiesQueue)
            }
            Spacer()
            Button(model.isRunning ? L("offload_hide") : L("close"),
                   action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(L("dailies_start")) { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canStartDailies)
        }
    }
}

/// The item in flight: which take, how far through it, and the two things a
/// visible run must offer — Skip and (in the footer) Stop. The bar is always
/// a bar, never a spinner, for the status strip's reason: a control that
/// changes shape makes everything under it jump.
struct DailiesProgressPanel: View {
    let progress: DailiesProgress
    /// Skip and the footer's Stop are one rule — "the queue is running and not
    /// already stopping" — so both ask `canSteerDailiesQueue` rather than each
    /// carrying its own copy of it. This panel used to be handed the flag as a
    /// value, which is how one rule becomes two spellings.
    @EnvironmentObject private var controller: CaptureController
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.rowSpacing) {
            HStack(spacing: 6) {
                Text(L("dailies_status", min(progress.itemIndex + 1,
                                             progress.itemCount),
                       progress.itemCount))
                    .offloadText(.section)
                if progress.isPaused {
                    // Why the bar is standing still, right next to it.
                    Label(L("dailies_paused_rec"), systemImage: "pause.circle")
                        .offloadText(.caption, tint: .orange)
                }
                Spacer(minLength: 2)
                Button(L("dailies_skip"), action: onSkip)
                    .disabled(!controller.canSteerDailiesQueue)
            }
            ProgressView(value: Double(progress.framesDone),
                         total: Double(max(1, progress.framesTotal)))
            HStack {
                Text(progress.currentFile)
                    .offloadText(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(L("dailies_frames", progress.framesDone,
                       progress.framesTotal))
                    .offloadText(.caption)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

/// The finished run: one line per outcome kind, failures named. Compact on
/// purpose — a dailies batch is routine, and the toast already carried the
/// verdict; this panel is for the one question a failure raises: which take.
struct DailiesResultPanel: View {
    /// About five failure lines. Enough that an ordinary bad batch is read
    /// without touching anything, bounded so a batch where everything failed
    /// cannot push the sheet past the window.
    static let failureListHeight: CGFloat = 110

    let report: DailiesReport

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
            Text(L("dailies_result_done", report.completed.count,
                   report.items.count))
                .offloadText(.section,
                             tint: report.isFullySucceeded ? .green : nil)
            // **The failure list is the one thing here that has no bound**,
            // and it is the reason this panel gets a scroll of its own: a
            // fourteen-take batch that all failed put the sheet 150pt over
            // the window, which is what used to make the WHOLE sheet scroll.
            //
            // A scroll rather than a "+N more" cap, because each line names a
            // take somebody has to go and redo — that is not a detail to
            // fold away. Five lines are visible and the rest are one flick
            // down, instead of the sheet growing without limit.
            if !report.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading,
                           spacing: OffloadChrome.tightSpacing) {
                        ForEach(report.failed, id: \.source) { item in
                            Label("\(item.source.lastPathComponent) — "
                                  + "\(item.failure ?? "")",
                                  systemImage: "exclamationmark.triangle.fill")
                                .offloadText(.caption, tint: .orange)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.failureListHeight)
            }
            // **A shelf a daily did not reach is not a failed item.** The
            // daily exists; what is missing is a copy of it, and a report that
            // called the item failed would be telling the operator the footage
            // has no daily when it has one.
            ForEach(report.items.filter { !$0.copyFailures.isEmpty },
                    id: \.source) { item in
                ForEach(item.copyFailures, id: \.self) { reason in
                    Label("\(item.source.lastPathComponent) — \(reason)",
                          systemImage: "arrow.right.circle")
                        .offloadText(.caption, tint: .orange)
                        .lineLimit(2)
                }
            }
            if report.wasCancelled {
                Text(L("dailies_result_cancelled"))
                    .offloadText(.caption)
            }
        }
    }
}

/// **How solid the burn-ins are**, folded away until it is wanted (owner:
/// "хотелось бы еще иметь возможность настроить опасити подложки и опасити
/// самого текста там отдельно для технических штук и отдельно для кастом
/// тайтла, как-нибудь ненавязчиво аккуратно").
///
/// A disclosure and not four rows on the face of the sheet: the panel is read
/// on a cart between takes, and these are set once for a show. Collapsed it
/// costs one row; open it costs two, which is what keeps the sheet inside the
/// window it has to fit (`ViewDailiesHeightTests`).
///
/// Two dials per group rather than one, because they answer different
/// questions — the plate is how much of the picture the strip hides, the text
/// is how much of the strip reads — and the two groups are separate because
/// the custom line is the one that gets pointed at the middle of the frame and
/// used as a watermark.
struct DailiesInkRows: View {
    @ObservedObject var model: DailiesQueueModel

    var body: some View {
        VStack(alignment: .leading, spacing: OffloadChrome.tightSpacing) {
            Text(L("dailies_ink_section"))
                .font(.callout)
                .foregroundStyle(.secondary)
            row(L("dailies_ink_technical"), ink: Binding(
                get: { model.ink }, set: { model.ink = $0 }))
            row(L("dailies_ink_custom"), ink: Binding(
                get: { model.customInk }, set: { model.customInk = $0 }))
        }
    }

    private func row(_ title: String, ink: Binding<DailiesInk>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .offloadText(.caption)
                .fixedSize()
            Spacer(minLength: 2)
            dial("rectangle.fill", help: L("dailies_ink_plate"),
                 value: Binding(get: { ink.wrappedValue.plate },
                                set: { ink.wrappedValue.plate = $0 }))
            dial("textformat", help: L("dailies_ink_text"),
                 value: Binding(get: { ink.wrappedValue.text },
                                set: { ink.wrappedValue.text = $0 }))
        }
    }

    /// One dial: an icon that names what it moves, and a mini slider. The icon
    /// rather than a word because two words per group in two languages is a
    /// row that stops fitting the column.
    private func dial(_ symbol: String, help: String,
                      value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .controlSize(.mini)
                .frame(width: 74)
        }
        .help(help)
    }
}
