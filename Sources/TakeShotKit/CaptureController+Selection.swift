import AppKit
import CaptureCore
import Foundation

/// Clicking around the takes panel.
///
/// The takes and the Other content block are ONE list to click through —
/// sweeping up the day's rejects, nobody cares which section a file landed in —
/// so the selection is a set of URLs across both, and every panel action reads
/// it the same way.
///
/// Split out of `+Takes`: what the operator has selected and what they have
/// marked on a take are separate jobs.
extension CaptureController {
    /// Every item in the panel, top to bottom: the takes as the list shows them
    /// (newest first), then Other content. This is the order a shift-click range
    /// spans and the order a Finder reveal hands over.
    var panelItemOrder: [URL] {
        takes.reversed().map(\.url) + otherFiles
    }

    /// The selection in the order it is shown.
    var selectedInOrder: [URL] {
        panelItemOrder.filter { selectedItems.contains($0) }
    }

    /// A click on a panel item with the keyboard as it stands.
    func clickPanelItem(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        clickPanelItem(url, command: modifiers.contains(.command),
                       shift: modifiers.contains(.shift))
    }

    /// cmd toggles this one item, shift extends from the anchor, a plain click
    /// selects it alone.
    func clickPanelItem(_ url: URL, command: Bool = false, shift: Bool = false) {
        if command {
            if selectedItems.contains(url) {
                selectedItems.remove(url)
            } else {
                selectedItems.insert(url)
            }
            selectionAnchor = url
        } else if shift, let range = shiftRange(to: url) {
            // The anchor deliberately stays where it was, and the range is added
            // to the selection rather than replacing it. Sweeping up the day's
            // rejects is cmd-click a few, then shift-click a run: measuring every
            // shift-click from the same anchor keeps the run one range instead of
            // chaining a new one from each click, and adding rather than
            // replacing keeps the cmd-clicked items. A plain click is how the
            // selection is started over — so shift-clicking back towards the
            // anchor does not shrink what is already selected.
            selectedItems.formUnion(range)
        } else {
            selectedItems = [url]
            selectionAnchor = url
        }
    }

    /// The items between the anchor and `url` inclusive; nil when there is no
    /// anchor yet or either end has left the panel.
    private func shiftRange(to url: URL) -> [URL]? {
        let order = panelItemOrder
        guard let anchor = selectionAnchor,
              let from = order.firstIndex(of: anchor),
              let to = order.firstIndex(of: url) else { return nil }
        return Array(order[min(from, to)...max(from, to)])
    }

    /// What a panel action applies to when the operator acts on `url`: the whole
    /// selection when `url` is part of it (the Finder rule), otherwise just the
    /// item that was clicked.
    func panelActionTargets(for url: URL) -> [URL] {
        selectedItems.contains(url) ? selectedInOrder : [url]
    }

    /// Show the selection — or just the clicked item — in Finder.
    func revealInFinder(_ url: URL) {
        let targets = panelActionTargets(for: url)
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    /// Items that left the panel leave the selection with them.
    func dropFromSelection(_ gone: Set<URL>) {
        guard !gone.isEmpty else { return }
        selectedItems.subtract(gone)
        if let anchor = selectionAnchor, gone.contains(anchor) {
            selectionAnchor = nil
        }
    }

    /// Anything no longer in the panel is no longer selected — a scan may have
    /// found the day's takes moved off to the archive.
    func pruneSelection() {
        dropFromSelection(selectedItems.subtracting(Set(panelItemOrder)))
    }
}
