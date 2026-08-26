import SwiftUI

/// The keyboard-shortcut editor, as a sheet over the settings window.
///
/// It used to be a section IN that window: fifteen rows of label-plus-button in
/// the middle of a form the operator opens to change a codec or a folder, and
/// the form scrolled past everything below it. A sheet gets the list its own
/// scroll and its own search field, and gives the settings form one row back.
///
/// A sheet rather than a seventh window scene: the editor is opened FROM
/// Settings, dismissed back to it, and is meaningless on its own — a window
/// would be one more thing to find on a second monitor and one more entry in
/// `AppWindows` to keep single-instance.
struct HotkeyEditorView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @StateObject private var model: HotkeyEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmResetAll = false

    /// Built with the manager the sheet's presenter already has, so the editor
    /// and the key-recording monitor act on ONE set of bindings.
    init(hotkeys: HotkeyManager) {
        _model = StateObject(wrappedValue: HotkeyEditorModel(hotkeys: hotkeys))
    }

    /// Wide enough for the longest action title beside the chord and reset
    /// columns without truncating in Russian, which runs half again as long
    /// (`ViewSettingsTests` measures every row against it).
    static let width: CGFloat = 560
    /// Tall enough for a dozen rows; the list scrolls past that rather than
    /// growing a sheet taller than a laptop screen.
    static let listHeight: CGFloat = 340
    /// The chord button's column. The same 90pt the old settings rows gave it.
    static let shortcutColumn: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let refusal = model.refusalText {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            list
            footer
        }
        .padding(16)
        .frame(width: Self.width)
        .background(controller.appBackground.ignoresSafeArea())
        .confirmationDialog(L("reset_hotkeys_confirm"),
                            isPresented: $confirmResetAll) {
            Button(L("reset_hotkeys"), role: .destructive) { model.resetAll() }
            Button(L("cancel"), role: .cancel) {}
        }
        // leaving with a row still capturing would swallow the next keypress in
        // whatever window the operator clicked into
        .onDisappear { hotkeys.recordingAction = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("settings_hotkeys"))
                .font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("hotkey_search"), text: $model.query)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("cancel"))
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if model.isEmpty {
            Text(L("hotkey_no_matches"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: Self.listHeight)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { action in
                        row(action)
                        Divider()
                    }
                }
            }
            .frame(height: Self.listHeight)
        }
    }

    private func row(_ action: HotkeyAction) -> some View {
        HStack(spacing: 8) {
            Text(L(action.titleKey))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.toggleRecording(action)
            } label: {
                Text(model.isRecording(action)
                     ? L("press_keys")
                     : model.combo(for: action).display)
                    .frame(minWidth: Self.shortcutColumn)
            }
            .tint(model.isRecording(action) ? controller.accentColor : nil)
            Button {
                model.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            // disabled(exception): per-ROW, like the slate steppers — whether
            // THIS action still holds its default binding. Named once on
            // `HotkeyEditorModel`, which owns the bindings the sheet is editing;
            // the controller has no opinion about them and there is one of these
            // buttons per action in the list.
            .disabled(!model.isCustomized(action))
            .help(L("hotkey_reset_one"))
            .accessibilityLabel(L("hotkey_reset_one"))
        }
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack {
            Button(L("reset_hotkeys"), role: .destructive) {
                confirmResetAll = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Spacer()
            Button(L("close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
