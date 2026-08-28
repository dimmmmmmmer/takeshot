import CaptureCore
import SwiftUI

// MARK: - shared take-row controls

/// Speech-bubble button that opens the take's log: the slate it was shot
/// under, what the shot is, and the free-text comment.
///
/// One button and one popover rather than a second control beside it: the
/// takes panel is 310pt wide at its narrowest and already carries a rating
/// toggle, and everything here is the same job — writing down what this take
/// was. Corrections land on the sidecars, never on the recorded file (see
/// `CaptureController+Slate` for why).
struct TakeLogButton: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take
    @State private var showPopover = false
    /// Everything the editor is holding, as one value — see `TakeLogDraft` for
    /// why the load and the save have to be inverses and why nothing could ask
    /// whether they were.
    @State private var draft = TakeLogDraft()
    @FocusState private var editorFocused: Bool

    /// Whether the take carries anything at all — the button is filled when it
    /// does, so a glance down the panel finds the logged takes. The same four
    /// fields the popover opens with, so a filled button never opens an empty
    /// editor.
    private var isLogged: Bool { !TakeLogDraft(of: take).isEmpty }

    var body: some View {
        Button {
            draft = TakeLogDraft(of: take)
            showPopover = true
        } label: {
            Image(systemName: isLogged ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 13))
                .foregroundStyle(isLogged ? controller.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(L("comment_help"))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            editor
        }
    }

    /// The rows under the slate follow the slate row's width rather than a
    /// number of their own: the row is a caption + arrows + box three times
    /// over and sets the popover's width on its own, and a 240pt description
    /// under it read as a mistake (see `SlateFieldsEditor.popoverContentWidth`).
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SlateFieldsEditor(scene: $draft.scene, shot: $draft.shot,
                              takeText: $draft.takeText)
            Text(L("description_label")).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $draft.logDescription)
                .textFieldStyle(.roundedBorder)
                .frame(width: SlateFieldsEditor.popoverContentWidth)
            Text(L("comment_label")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.comment)
                .font(.body)
                .frame(width: SlateFieldsEditor.popoverContentWidth, height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.secondary.opacity(0.3)))
                .focused($editorFocused)
                .onAppear { editorFocused = true }
            // Said out loud rather than left to be discovered: the operator is
            // correcting a file that has already been written, and has to know
            // the fix travels in the sidecars.
            Text(L("slate_sidecar_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: SlateFieldsEditor.popoverContentWidth,
                       alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("comment_save")) {
                    save()
                    showPopover = false
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(12)
    }

    /// Both writes go through the controller, which files them on the take list
    /// and the sidecars and never on the recorded file (`CaptureController+Slate`
    /// says why). The draft decides what they say — including how the TAKE
    /// field is read, which this used to answer for itself by keeping the first
    /// four DIGITS typed, so an operator who typed 12345 here logged take 1234
    /// and one who typed it into the footer logged 9999.
    private func save() {
        controller.setComment(draft.comment, for: take)
        controller.setSlate(draft.slate, description: draft.logDescription,
                            for: take)
    }
}

struct RatingToggle: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button {
            controller.cycleRating(take)
        } label: {
            Group {
                switch take.rating {
                case .none:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .good:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .bad:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 13))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(L("rating_help"))
    }
}

struct TakeContextMenu: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take

    var body: some View {
        Button(L("play")) { controller.play(url: take.url) }
        // enabled by the selection, not the clicked row: comparing needs 2–4
        // takes picked first, and a grey item teaches that better than a
        // missing one
        Button(L("sync_play_menu")) { controller.startSyncPlay() }
            .disabled(!controller.canStartSyncPlay)
        Divider()
        Button(L("good_take")) { controller.setRating(.good, for: take) }
        Button(L("bad_take")) { controller.setRating(.bad, for: take) }
        Button(L("clear_rating")) { controller.setRating(.none, for: take) }
        Divider()
        PanelItemActions(url: take.url) { controller.deleteTake(take) }
    }
}

/// Reveal + Trash for one panel item, and the same two for the whole selection
/// when the item that was right-clicked belongs to it — the rule Finder uses.
///
/// Trashing several items goes through the confirmation dialog on the panel;
/// trashing the one item under the cursor does not, because that is a deliberate
/// click on a named menu entry, not a key that is easy to hit by accident.
struct PanelItemActions: View {
    @EnvironmentObject private var controller: CaptureController
    let url: URL
    let deleteOne: () -> Void

    var body: some View {
        let targets = controller.panelActionTargets(for: url)
        if targets.count > 1 {
            let count = localizedItemCount(targets.count)
            Button(L("reveal_selection", count)) { controller.revealInFinder(url) }
            Divider()
            Button(L("trash_selection", count), role: .destructive) {
                controller.trashPromptOpen = true
            }
        } else {
            Button(L("show_in_finder")) { controller.revealInFinder(url) }
            Divider()
            Button(L("delete_item"), role: .destructive, action: deleteOne)
        }
    }
}
