import CaptureCore
import Foundation
import SwiftUI

/// One end of the copy: the card on the left of the operation, a destination on
/// the right of it, drawn exactly the same way (owner item 22).
///
/// The source used to be a line of text while the destinations were icon rows,
/// so the two halves of one operation did not look like halves of anything. A
/// destination is not more important than the card — pick the wrong card and
/// three verified copies of the wrong thing are what you get — and nothing about
/// the old layout said the two were even related.
///
/// Everything a tile shows is cheap: a name, the path under it, and one line of
/// numbers off two `stat`-level resource reads. No tree is walked. The sheet is
/// drawn with a card in the reader, and enumerating a full one is hundreds of
/// milliseconds of I/O on the main thread.
struct OffloadPathTile<Controls: View>: View {
    /// SF Symbol. A volume gets the drive, a folder gets the folder — the
    /// operator picks both kinds here and the two are worth telling apart.
    let icon: String
    /// The name to lead with, or the "nothing chosen yet" line.
    let title: String
    /// Full path, under the name. nil when nothing is chosen.
    let path: String?
    /// The numbers line: free/used space, and where a destination's copy lands.
    let detail: String?
    /// Nothing is chosen: the title is a prompt rather than a name.
    let isEmpty: Bool
    /// What the Finder button opens; nil hides the button.
    let finderTarget: URL?
    /// Choose / Remove — whatever this end of the operation can do.
    let controls: Controls

    init(icon: String, title: String, path: String? = nil,
         detail: String? = nil, isEmpty: Bool = false,
         finderTarget: URL? = nil,
         @ViewBuilder controls: () -> Controls) {
        self.icon = icon
        self.title = title
        self.path = path
        self.detail = detail
        self.isEmpty = isEmpty
        self.finderTarget = finderTarget
        self.controls = controls()
    }

    var body: some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(.secondary))
                .frame(width: OffloadChrome.tileIconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .offloadText(.body, tint: isEmpty ? .secondary : nil)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let path {
                    Text(path)
                        .offloadText(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail {
                    Text(detail)
                        .offloadText(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let finderTarget {
                Button {
                    FinderOpen.folder(finderTarget)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help(L("offload_open_dest"))
            }
            controls
        }
        .padding(OffloadChrome.cardPadding)
        .background(Color.secondary.opacity(OffloadChrome.tilePlateOpacity),
                    in: RoundedRectangle(cornerRadius: OffloadChrome.cardRadius))
    }
}

/// What a tile can say about a folder without walking it.
///
/// Two resource reads and no enumeration. The numbers are the ones actually
/// being checked at this moment — can this disk hold the card, and how full is
/// the card — and neither needs to know what the files are.
enum OffloadVolumeFacts {
    /// A volume's size and what is left on it.
    struct Capacity: Equatable {
        var total: Int64
        var free: Int64

        var used: Int64 { max(0, total - free) }
    }

    /// nil for a path that is not there, which is the normal state of a
    /// destination the operator saved last week and has not plugged in yet.
    static func capacity(of url: URL) -> Capacity? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Capacity(total: Int64(total), free: Int64(free))
    }

    /// What the tile leads with. The mount name for a volume, the folder name
    /// otherwise — and the path itself for a root, which has no last component.
    static func name(of url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? url.path : last
    }

    /// "1.2 TB free of 4.0 TB" — what a destination is asked.
    static func freeText(of url: URL) -> String? {
        guard let capacity = capacity(of: url) else { return nil }
        return L("offload_space_free",
                 OffloadFormat.shortBytes(capacity.free),
                 OffloadFormat.shortBytes(capacity.total))
    }

    /// "312 GB used of 512 GB" — what a card is asked. The same two numbers as
    /// above, the other way round: on a destination what matters is the room
    /// left, on a card it is how much there is to copy.
    static func usedText(of url: URL) -> String? {
        guard let capacity = capacity(of: url) else { return nil }
        return L("offload_space_used",
                 OffloadFormat.shortBytes(capacity.used),
                 OffloadFormat.shortBytes(capacity.total))
    }

    /// The drive for a volume, a folder for anything else. A card in a reader
    /// and a subfolder of a working disk are picked through the same button and
    /// behave differently, and the icon is the cheapest way to say which one is
    /// in the slot.
    static func icon(for url: URL) -> String {
        isVolumeRoot(url) ? "externaldrive" : "folder"
    }

    /// Is this URL a volume's mount point? Compared by path rather than by URL
    /// equality: `volumeURLKey` comes back standardized and the URL the
    /// operator picked in a panel does not have to be.
    static func isVolumeRoot(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey])
            .volume else { return false }
        return volume.standardized.path == url.standardized.path
    }
}
