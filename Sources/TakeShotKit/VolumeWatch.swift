import AppKit
import Foundation

/// One mounted volume, as the card watch sees it.
///
/// A value rather than a bare URL because the recognition heuristic needs the
/// volume's own attributes — removable, ejectable, local, browsable — and those
/// cannot be read back off a scratch directory in a test. The watch is the layer
/// that knows how to obtain them; everything downstream is handed the answers.
struct MountedVolume: Equatable, Sendable {
    /// The mount point.
    var url: URL
    /// What the operator sees in the Finder sidebar.
    var name: String
    /// The volume's own UUID. nil on filesystems that do not carry one — the
    /// ledger then falls back to the mount path (see `CardCandidate.key`).
    var uuid: String?
    /// Removable media in the "the medium leaves the drive" sense (an SD card
    /// in a reader).
    var isRemovable: Bool
    /// The whole device can be unmounted and unplugged (a card reader, a USB
    /// SSD). The two are separate in the filesystem's eyes and a card reader
    /// reports them differently depending on the reader, so both are kept.
    var isEjectable: Bool
    /// False for anything reached over the network. A share that appears on the
    /// set Wi-Fi is not a card, and walking it to find out is a stall.
    var isLocal: Bool
    /// What the Finder would show in the sidebar. False for the internal
    /// system mounts that appear and disappear on their own.
    var isBrowsable: Bool

    init(url: URL, name: String, uuid: String? = nil, isRemovable: Bool = false,
         isEjectable: Bool = false, isLocal: Bool = true,
         isBrowsable: Bool = true) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
    }

    /// Removable in the sense that matters here: the operator can pull it out
    /// and walk away with it. Either flag is enough — USB card readers report
    /// ejectable-but-not-removable, internal SD slots the other way round.
    var isDetachable: Bool { isRemovable || isEjectable }
}

/// Where mount and unmount events come from.
///
/// A protocol because the tests must never touch a real volume: the suite injects
/// a fake that reports synthetic mounts over scratch directories it populated as
/// fake cards. Mounting an actual disk image per test would be slow, would need
/// privileges no CI runner has, and would leave a mounted volume behind whenever
/// a test failed part way.
@MainActor
protocol VolumeWatching: AnyObject {
    var onMount: ((MountedVolume) -> Void)? { get set }
    var onUnmount: ((URL) -> Void)? { get set }
    func start()
    func stop()
}

/// The real thing: `NSWorkspace`'s mount notifications.
///
/// **No initial enumeration, on purpose.** Only volumes that mount while the app
/// is running are offered. Everything already attached at launch has been sitting
/// there — very often the destination SSDs themselves — and greeting the operator
/// with a stack of offers for disks they mounted an hour ago is how a prompt
/// stops being read.
@MainActor
final class WorkspaceVolumeWatch: VolumeWatching {
    var onMount: ((MountedVolume) -> Void)?
    var onUnmount: ((URL) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didMountNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(from: note) else { return }
                // The notification arrives on the main queue and the handler is
                // MainActor work, but the closure itself is not isolated.
                MainActor.assumeIsolated { self?.deliverMount(url) }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(from: note) else { return }
                MainActor.assumeIsolated { self?.onUnmount?(url) }
            },
        ]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private func deliverMount(_ url: URL) {
        onMount?(Self.describe(url))
    }

    /// `nonisolated`: it is called from the notification closure, which is not
    /// isolated to anything, and reading a key out of a userInfo dictionary
    /// needs no actor.
    nonisolated private static func volumeURL(from note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    /// Read the volume's attributes once, here, so nothing downstream has to
    /// touch the filesystem to find out what kind of disk it is looking at.
    static func describe(_ url: URL) -> MountedVolume {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return MountedVolume(
            url: url,
            name: values?.volumeName ?? url.lastPathComponent,
            uuid: values?.volumeUUIDString,
            isRemovable: values?.volumeIsRemovable ?? false,
            isEjectable: values?.volumeIsEjectable ?? false,
            // Unreadable means "assume it is a normal local disk": the
            // recognition heuristic below is what decides, and defaulting to
            // "not local" here would silently switch the whole feature off on a
            // filesystem that does not answer the question.
            isLocal: values?.volumeIsLocal ?? true,
            isBrowsable: values?.volumeIsBrowsable ?? true)
    }
}
