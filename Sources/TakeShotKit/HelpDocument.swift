import Foundation

/// The operator guide, as blocks ready to render.
///
/// The text itself is a Markdown file per language under
/// `Resources/<lang>.lproj/Help.md`, NOT a wall of L() keys: it is prose, it is
/// several pages of it, and prose in a .strings file is unreadable to whoever
/// has to keep it true — every paragraph one escaped line, merged by hand
/// against every other string the app adds.
///
/// Only the small Markdown subset the guide is written in is understood, and it
/// is understood strictly: an unrecognized construct renders as the paragraph it
/// is rather than disappearing. Inline emphasis and `code` are left to
/// AttributedString, which parses them at render time.
struct HelpDocument: Equatable {
    enum BlockKind: Equatable {
        case title      // "# " — once, at the top
        case section    // "## "
        case paragraph
        case bullet     // "- "
    }

    /// One rendered element. Deliberately not a tree: the guide is a flat
    /// sequence of headings, paragraphs and bullets, and a tree would need a
    /// renderer nobody can check by eye.
    struct Block: Equatable, Identifiable {
        let id: Int
        let kind: BlockKind
        let text: String
    }

    /// The document title (the `#` line), for the window and the test that the
    /// two languages stayed in step.
    let title: String
    let blocks: [Block]

    var sections: [Block] { blocks.filter { $0.kind == .section } }

    /// The guide for the language currently in force. Empty when the resource is
    /// missing, which the help view says out loud instead of showing a blank
    /// page — a silently empty manual reads as a broken app.
    static func current() -> HelpDocument {
        parse(loadMarkdown() ?? "")
    }

    /// `Help.md` from the language bundle L10n is holding, falling back to the
    /// module's own (the "system language" case, and a language whose .lproj is
    /// missing).
    static func loadMarkdown() -> String? {
        for bundle in [L10n.resources, Bundle.module] {
            guard let url = bundle.url(forResource: "Help", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            return text
        }
        return nil
    }

    /// Markdown → blocks. Paragraphs are joined across their soft-wrapped source
    /// lines: the file is wrapped at 80 columns for whoever edits it, and
    /// rendering those breaks would put a ragged edge down the middle of the
    /// window.
    static func parse(_ markdown: String) -> HelpDocument {
        var title = ""
        var blocks: [Block] = []
        var pending: [String] = []
        var pendingKind = BlockKind.paragraph

        func flush() {
            let text = pending.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            pending = []
            guard !text.isEmpty else { return }
            blocks.append(Block(id: blocks.count, kind: pendingKind, text: text))
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A blank line, a heading or a new bullet all end whatever was open;
            // anything else continues it (that is what makes a wrapped
            // paragraph, and an indented continuation of a bullet, one block).
            if line.isEmpty {
                flush()
            } else if let heading = line.dropPrefix("## ") {
                flush()
                pendingKind = .section
                pending = [String(heading)]
                flush()
                pendingKind = .paragraph
            } else if let heading = line.dropPrefix("# ") {
                flush()
                if title.isEmpty { title = String(heading) }
                pendingKind = .title
                pending = [String(heading)]
                flush()
                pendingKind = .paragraph
            } else if let bullet = line.dropPrefix("- ") {
                flush()
                pendingKind = .bullet
                pending = [String(bullet)]
            } else {
                pending.append(line)
            }
        }
        flush()
        return HelpDocument(title: title, blocks: blocks)
    }
}

private extension String {
    /// The rest of the line after `prefix`, or nil when it does not start with
    /// it. `hasPrefix` + `dropFirst(n)` twice per branch is where an off-by-one
    /// eats the first letter of a heading.
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
