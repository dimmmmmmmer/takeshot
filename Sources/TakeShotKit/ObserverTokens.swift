import AppKit
import Foundation

/// Owners for the opaque tokens `NotificationCenter` and `NSEvent` hand back.
/// Each gives its tokens up when it is released.
///
/// They exist because `deinit` stays nonisolated on a main-actor class while the
/// tokens are typed `any NSObjectProtocol` and `Any` — neither of them Sendable
/// — so a main-actor object may not reach its own observer list on the way out.
/// A plain nonisolated object may: nothing about it is isolated, so its own
/// `deinit` reaches its own stored properties, and the main-actor owner's
/// `deinit` has only to RELEASE it. Where and when the deallocation happens is
/// unchanged, and so is the thread the unregistering runs on: whichever one
/// drops the last reference, exactly as before.
///
/// Not an actor and not locked, deliberately. Both of these are touched only by
/// their owner, which is main-actor isolated, plus the release at the end — the
/// same confinement the owners already had.
final class NotificationTokens {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    /// `NSWorkspace` posts on a centre of its own, so the centre is stated
    /// rather than assumed — an observer removed from the wrong one stays.
    init(center: NotificationCenter = .default) {
        self.center = center
    }

    var isEmpty: Bool { tokens.isEmpty }

    func add(_ token: any NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}

/// One `NSEvent` monitor at a time, removed when it is replaced, cleared, or
/// released (see `NotificationTokens` above for why this is its own object).
final class EventMonitorToken {
    private var monitor: Any?

    var isActive: Bool { monitor != nil }

    /// Replacing an active monitor removes it first: two monitors on one view
    /// would both be handed the same pinch, and it would be applied twice.
    func set(_ monitor: Any?) {
        remove()
        self.monitor = monitor
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }
}
