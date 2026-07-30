import SwiftUI

/// The help window: the operator guide for the language in force.
///
/// A window rather than a sheet or a popover — it is read WHILE the app is
/// being used, next to the thing it is describing, and on a shoot that means
/// dragging it onto the second screen.
struct HelpView: View {
    /// Wide enough for a full line of the guide without the eye losing the
    /// start of the next one; the window is resizable from here.
    static let width: CGFloat = 620
    static let padding: CGFloat = 24
    /// Width left for the text itself.
    static var contentWidth: CGFloat { width - padding * 2 }

    /// Rebuilt when the language changes: the document is loaded from the
    /// language bundle, so the whole view has to be re-read, not just relabelled.
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ScrollView {
            HelpBody(document: HelpDocument.current())
                .padding(Self.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(controller.settings.appLanguage)
    }
}

/// The guide's blocks. Split out of the window so a test can measure the text
/// without a ScrollView answering for it (a scroll view reports the proposal it
/// was handed, whatever is inside it).
struct HelpBody: View {
    let document: HelpDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if document.blocks.isEmpty {
                // Better an honest line than a blank window: this means the
                // Help.md resource did not make it into the bundle.
                Text(L("help_unavailable"))
                    .foregroundStyle(.secondary)
            }
            ForEach(document.blocks) { block in
                HelpBlockView(block: block)
            }
        }
    }
}

private struct HelpBlockView: View {
    let block: HelpDocument.Block

    var body: some View {
        switch block.kind {
        case .title:
            Text(inline)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 2)
        case .section:
            Text(inline)
                .font(.headline)
                .padding(.top, 12)
        case .paragraph:
            Text(inline)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(inline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
    }

    /// Emphasis and `code` come from AttributedString's own Markdown parse;
    /// text that does not parse is shown as written rather than dropped.
    private var inline: AttributedString {
        (try? AttributedString(markdown: block.text)) ?? AttributedString(block.text)
    }
}
