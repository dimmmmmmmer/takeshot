import AppKit
import Combine

/// The `NSStatusItem` itself: an icon that says what the recorder is doing, the
/// running take's timecode beside it, and a menu built at click time from
/// `MenuBarModel.items`.
///
/// Everything decidable lives in the model (see there); this type is the AppKit
/// surface and holds no state of its own beyond what it last handed to the
/// system, which is how a state that has not moved costs nothing to redraw.
///
/// This does NOT make TakeShot an accessory app. The activation policy stays
/// `.regular` — the dock icon, the app menu and the main window are all still
/// there. The status item is an addition, for the times the window is behind
/// something else or closed.
@MainActor
final class MenuBarPresence: NSObject, NSMenuDelegate {
    let model: MenuBarModel

    private let statusItem: NSStatusItem
    private var sink: AnyCancellable?
    /// What the system is currently showing, so an unchanged state is not
    /// pushed at it again. The model publishes on every controller change; the
    /// button only has two things on it.
    private var shown: (presence: MenuBarModel.Presence, title: String)?

    init(model: MenuBarModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        // The model decides enablement (a Stop item while idle is a lie); with
        // autoenabling on, AppKit would decide it instead — from whether a
        // responder answers the action — and light up the take-name row.
        menu.autoenablesItems = false
        statusItem.menu = menu
        // objectWillChange fires BEFORE the value lands, so the button is
        // redrawn on the next turn — by which time `shown` makes an unchanged
        // state free.
        sink = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshButton() }
        }
        refreshButton()
    }

    /// Take the item out of the menu bar. Explicit rather than a `deinit`
    /// because the teardown is main-actor work and a deinit is not.
    func remove() {
        sink = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - the button

    func refreshButton() {
        guard let button = statusItem.button else { return }
        let state = (presence: model.presence, title: model.statusTitle)
        guard shown == nil || shown! != state else { return }
        shown = state
        button.image = Self.image(for: model)
        // Monospaced digits: a proportional timecode re-lays the whole menu bar
        // out every time a 1 becomes a 0.
        button.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        button.title = state.title.isEmpty ? "" : " " + state.title
        button.imagePosition = state.title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = model.tooltip
    }

    private static func image(for model: MenuBarModel) -> NSImage? {
        guard let image = NSImage(systemSymbolName: model.symbolName,
                                  accessibilityDescription: model.tooltip)
        else { return nil }
        guard model.isAlarmColored else {
            image.isTemplate = true
            return image
        }
        // A template image is tinted by the system (black, or white in a dark
        // menu bar); the REC indicator has to stay red in both.
        let red = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        red?.isTemplate = false
        return red ?? image
    }

    // MARK: - the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in model.items { menu.addItem(menuItem(for: item)) }
    }

    private func menuItem(for item: MenuBarModel.Item) -> NSMenuItem {
        guard !item.isSeparator else { return .separator() }
        let menuItem = NSMenuItem(title: item.title, action: nil,
                                  keyEquivalent: "")
        menuItem.state = item.checked ? .on : .off
        menuItem.isEnabled = item.enabled
        if let command = item.command, item.enabled {
            menuItem.action = #selector(fire(_:))
            menuItem.target = self
            menuItem.representedObject = command.rawValue
        }
        return menuItem
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = MenuBarModel.Command(rawValue: raw) else { return }
        model.perform(command)
    }
}
