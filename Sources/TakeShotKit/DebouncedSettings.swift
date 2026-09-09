import Foundation

/// **Every settings write that waits, and the one place they are all flushed.**
///
/// Five values are written to settings on a debounce — the monitor volume, the
/// mute and dim holds, the assist state and the LUT intensity — because each of
/// them is driven by a slider or a key an operator can move ten times a second,
/// and a settings write per move is a JSON encode per move.
///
/// The debounce had no flush. `flushOnTerminate` emptied ONE of the five (the
/// visual-rec box, added last and with its own line), so a level set inside the
/// last 400 ms before Quit was simply gone (owner: "я вижу что он не сохранил
/// после шатдауна… установленную громкость звука"). Each of those writes is a
/// value the operator SET and would expect back.
///
/// A `Slot` per value rather than a task per call site, and `flushAll` over the
/// whole set rather than five named calls, so the next debounced setting cannot
/// arrive without a flush: adding one means adding a case here, and the flush
/// already covers it.
@MainActor
final class DebouncedSettings {
    /// One debounced value. The case list IS the set that gets flushed.
    enum Slot: CaseIterable {
        case monitorVolume
        case monitorMute
        case monitorDim
        case assist
        case lutIntensity
        case visualRec
    }

    private var tasks: [Slot: Task<Void, Never>] = [:]
    /// What each slot would write if it fired. Held so a flush can write it
    /// NOW instead of waiting out a sleep nobody is going to wait for.
    private var pending: [Slot: () -> Void] = [:]

    /// Write `apply` after `delay`, replacing whatever that slot was going to
    /// write. The last value wins, which is what a debounce is for.
    func schedule(_ slot: Slot, after delay: Duration,
                  _ apply: @escaping () -> Void) {
        tasks[slot]?.cancel()
        pending[slot] = apply
        tasks[slot] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.run(slot)
        }
    }

    /// Drop a slot's pending write without performing it — for a value that
    /// has been superseded by a write from somewhere else.
    func cancel(_ slot: Slot) {
        tasks[slot]?.cancel()
        tasks[slot] = nil
        pending[slot] = nil
    }

    /// Write one slot's pending value immediately.
    func flush(_ slot: Slot) {
        tasks[slot]?.cancel()
        tasks[slot] = nil
        run(slot)
    }

    /// **Write everything that is waiting.** Called on the way out, before
    /// anything blocks: the whole point is that a value set a moment ago is
    /// still there on the next launch.
    func flushAll() {
        for slot in Slot.allCases { flush(slot) }
    }

    /// Whether anything is waiting — for the tests, which cannot see a task.
    var isPending: Bool { !pending.isEmpty }

    func isPending(_ slot: Slot) -> Bool { pending[slot] != nil }

    private func run(_ slot: Slot) {
        guard let apply = pending.removeValue(forKey: slot) else { return }
        apply()
    }
}
