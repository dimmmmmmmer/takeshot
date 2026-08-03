import CaptureCore
import Foundation
import SwiftUI

/// Choosing one of the app's own files, wherever the app asks for one.
///
/// Two places ask: the compare bar wants the clip on the other side of the
/// wipe, and the chroma key wants the plate behind the actor. Both used to
/// answer the question their own way — the compare menu listed the takes and
/// nothing else, the key had a file panel and nothing else — and neither of them
/// separated the day's takes from the Other content that happens to be sitting
/// in the same folder. One list mixing the two is unreadable by the third
/// reference file of the day.
///
/// So: one source of truth for what can be picked (`mediaSources`), grouped, and
/// one view that renders the groups (`MediaSourceMenuItems`).

/// One pickable file.
struct MediaSourceItem: Identifiable, Hashable {
    let url: URL
    /// What the row says. A take's own display name, an Other file's file name.
    let name: String

    var id: URL { url }
}

/// The two things a record folder holds, which an operator never confuses and a
/// mixed list forces them to.
enum MediaSourceGroup: String, CaseIterable, Identifiable {
    /// Shot by this app, in this session or a previous one.
    case takes
    /// Everything else that turned up in the record folder.
    case other

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .takes: return "media_group_takes"
        case .other: return "other_content"
        }
    }
}

/// A group and what is in it. Groups with nothing in them are dropped by
/// `mediaSources`, so a picker never shows an empty heading.
struct MediaSourceGroupItems: Identifiable {
    let group: MediaSourceGroup
    let items: [MediaSourceItem]

    var id: String { group.rawValue }
}

/// What a picker will accept.
enum MediaSourceKind {
    /// Anything the app can turn into a picture — clips and stills both.
    case any
    /// Clips only, for the things that need a transport (the compare B side).
    case video
}

extension CaptureController {
    /// The app's own media as a picker shows it: takes first, then Other
    /// content, each under its own heading and never merged.
    func mediaSources(_ kind: MediaSourceKind) -> [MediaSourceGroupItems] {
        let takes = takes
            .filter { Self.mediaSource($0.url, matches: kind) }
            .map { MediaSourceItem(url: $0.url, name: $0.displayName) }
        let others = otherFiles
            .filter { Self.mediaSource($0, matches: kind) }
            .map { MediaSourceItem(url: $0, name: $0.lastPathComponent) }
        return [MediaSourceGroupItems(group: .takes, items: takes),
                MediaSourceGroupItems(group: .other, items: others)]
            .filter { !$0.items.isEmpty }
    }

    /// The name to show for a URL a picker chose, whichever group it came from.
    /// nil when the file is not in either — a clip that has since been trashed,
    /// or one dragged in from outside the record folder.
    func mediaSourceName(for url: URL) -> String? {
        if let take = takes.first(where: { $0.url == url }) {
            return take.displayName
        }
        return otherFiles.contains(url) ? url.lastPathComponent : nil
    }

    /// Extension only, and no look at the disk: this is asked once per file
    /// every time a menu is built, and a `fileExists` per row is a stall with no
    /// visible cause. A CinemaDNG folder is not offered — it has no extension to
    /// judge and neither consumer can take one.
    nonisolated private static func mediaSource(_ url: URL,
                                                matches kind: MediaSourceKind) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .any:
            return videoExtensions.contains(ext) || imageExtensions.contains(ext)
        case .video:
            return videoExtensions.contains(ext)
        }
    }
}

/// The grouped rows themselves, as menu content.
///
/// A `Section` per group rather than a divider and a disabled title row: on
/// macOS that is what puts a real heading above the items, and it keeps the two
/// groups apart even when one of them is a single file.
struct MediaSourceMenuItems: View {
    let groups: [MediaSourceGroupItems]
    /// What is chosen now, so the row can carry the tick.
    let selection: URL?
    let choose: (URL) -> Void

    var body: some View {
        ForEach(groups) { group in
            Section(L(group.group.labelKey)) {
                ForEach(group.items) { item in
                    Button {
                        choose(item.url)
                    } label: {
                        if selection == item.url {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            }
        }
    }
}
