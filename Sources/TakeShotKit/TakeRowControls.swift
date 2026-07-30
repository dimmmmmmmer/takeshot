import CaptureCore
import SwiftUI

// MARK: - shared take-row controls

/// Speech-bubble button that opens a popover to edit a take's free-text comment.
struct CommentButton: View {
    @EnvironmentObject private var controller: CaptureController
    let take: Take
    @State private var showPopover = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        Button {
            draft = take.comment
            showPopover = true
        } label: {
            Image(systemName: take.comment.isEmpty ? "bubble.left" : "bubble.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(take.comment.isEmpty ? Color.secondary : controller.accentColor)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(L("comment_help"))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("comment_label")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(width: 240, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.secondary.opacity(0.3)))
                    .focused($editorFocused)
                    .onAppear { editorFocused = true }
                HStack {
                    Spacer()
                    Button(L("comment_save")) {
                        controller.setComment(draft, for: take)
                        showPopover = false
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(12)
        }
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
