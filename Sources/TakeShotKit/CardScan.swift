import Foundation

/// Why a mounted volume is being offered for offload.
///
/// Carried into the prompt and shown there. The operator is the one who knows
/// what they plugged in; the app's job is to say what it saw and let them judge
/// — a prompt that says only "Offload?" over a disk the app guessed wrong about
/// is how the operator learns to click Ignore without reading.
enum CardEvidence: Equatable, Sendable {
    /// A camera folder structure at the volume root, named. Strong: nothing but
    /// a camera writes `XDROOT`.
    case cameraStructure(String)
    /// No known structure, but the volume can be unplugged and carries video
    /// files. A maybe, and the prompt says so — a USB stick with a couple of
    /// MP4s on it looks exactly like this.
    case detachableVideo(Int)
}

/// A mounted volume that looks like camera media, with everything the prompt and
/// the ledger need about it.
struct CardCandidate: Equatable, Sendable {
    var volume: MountedVolume
    /// Every file on it — hidden ones included, because that is what an offload
    /// would copy (see `OffloadEngine.scan`).
    var files: Int
    var bytes: Int64
    var evidence: CardEvidence

    var url: URL { volume.url }
    var name: String { volume.name }

    /// How the ledger recognises this card again.
    ///
    /// The volume UUID when there is one: a card keeps it across remounts and
    /// across readers, which is exactly the identity wanted. The mount path is
    /// the fallback for filesystems that carry no UUID — weaker (a second card
    /// mounted at the same path after the first was ejected looks like the same
    /// card), which is why the fingerprint below is checked as well.
    var key: String {
        volume.uuid ?? volume.url.standardized.path
    }

    /// What was on the card when it was offloaded. A card that has been shot on
    /// since is a different card as far as the offer is concerned, and the whole
    /// point of the ledger is that it must be offered again.
    var fingerprint: CardFingerprint {
        CardFingerprint(files: files, bytes: bytes)
    }

    /// The reason, in the operator's language.
    var reasonText: String {
        switch evidence {
        case .cameraStructure(let folder):
            return L("card_reason_structure", folder)
        case .detachableVideo(let count):
            return L("card_reason_video", count)
        }
    }
}

/// File count and total size — enough to notice that a card has been shot on
/// since it was last copied, and cheap enough to compute on every mount.
///
/// Not a checksum: hashing a 512 GB card to decide whether to ASK about copying
/// it would take longer than the copy. Two numbers cannot distinguish a card
/// whose contents were replaced by exactly as many bytes in exactly as many
/// files, and that is an acceptable miss for a prompt — the offload itself
/// verifies every byte.
struct CardFingerprint: Codable, Equatable, Sendable {
    var files: Int
    var bytes: Int64
}

/// Deciding whether a mounted volume is camera media.
///
/// **The heuristic, and what it is willing to be wrong about.** A false positive
/// costs one dismissible line in the takes panel. A false negative costs the
/// operator nothing they had before this feature existed — they open the offload
/// sheet the way they always did. So the bias is deliberately towards offering,
/// with one exception: volumes that are obviously NOT footage (a Time Machine
/// destination, a disk that already holds offloads) are refused outright rather
/// than offered as a maybe, because those are the ones where a wrong offer is
/// actively alarming.
enum CardScan {
    /// Root folders that mean "a camera wrote this". Matched case-insensitively
    /// against the volume's own root; `PRIVATE/AVCHD` and `PRIVATE/M4ROOT` are
    /// checked one level down as well, which is where the camcorders put them.
    static let cameraFolders = [
        "DCIM",      // stills bodies, mirrorless video, GoPro, DJI, drones
        "AVCHD",     // AVCHD camcorders that put it at the root
        "CLIPS",     // Blackmagic and several others
        "XDROOT",    // Sony XDCAM
        "BPAV",      // Sony XDCAM EX
        "M4ROOT",    // Sony XAVC / NXCAM
        "CONTENTS",  // Panasonic P2, and the RED/ARRI-shaped layouts
        "PRIVATE",   // the wrapper AVCHD and M4ROOT live under
    ]

    /// Nested structures, as `parent/child`. `PRIVATE` alone is weak — plenty of
    /// non-camera disks have one — so it only counts when what is inside it is a
    /// camera folder.
    static let nestedCameraFolders = [
        "PRIVATE/AVCHD", "PRIVATE/M4ROOT", "PRIVATE/BPAV",
    ]

    /// What a camera writes. Deliberately NOT
    /// `CaptureController.videoExtensions`: that set is "clips this app can put
    /// in the player", and it would neither recognise the AVCHD stream files
    /// (`.mts`) nor the camera-original RAW containers that make a card a card.
    static let cameraVideoExtensions: Set<String> = [
        "mov", "mp4", "mxf", "m4v", "avi", "braw", "r3d", "mts", "m2ts",
        "mpg", "mpeg", "crm", "ari", "arx", "cine", "dng", "insv",
    ]

    /// Roots that mean "this is not a card, and do not ask": a Time Machine
    /// destination, or a disk that already holds verified offloads.
    static let refusedRootEntries = [
        "Backups.backupdb",                  // Time Machine, HFS+
        ".com.apple.timemachine.supported",  // Time Machine, any filesystem
        ".com.apple.timemachine.donotpresent",
        "ascmhl",                            // an offload DESTINATION, not a card
    ]

    /// A tree this large is not a camera card, whatever is at its root — it is a
    /// working disk or a library, and walking all of it to say so would stall the
    /// scan for seconds. The cap bounds the worst case; nothing camera-shaped
    /// comes anywhere near it (a full 1 TB card of 4-second clips is ~30k files).
    static let entryCap = 200_000

    /// Look at a freshly mounted volume. nil — do not offer it.
    ///
    /// `nonisolated` and pure: it walks a directory tree, which is I/O measured
    /// in hundreds of milliseconds on a full card, and the caller runs it off the
    /// MainActor (see `CaptureController.handleVolumeMount`).
    nonisolated static func inspect(_ volume: MountedVolume) -> CardCandidate? {
        // A share on the set Wi-Fi is not a card, and walking it to find out is
        // the stall. Non-browsable volumes are the internal system mounts the
        // Finder itself hides.
        guard volume.isLocal, volume.isBrowsable else { return nil }
        let root = (try? FileManager.default.contentsOfDirectory(
            atPath: volume.url.path)) ?? []
        let rootSet = Set(root.map { $0.lowercased() })
        guard !refusedRootEntries.contains(where: {
            rootSet.contains($0.lowercased())
        }) else { return nil }

        let structure = matchedStructure(at: volume.url, root: rootSet)
        let walk = measure(volume.url)
        // An empty card is a formatted card. There is nothing to copy and
        // nothing to lose, and asking about it is pure noise.
        guard walk.files > 0 else { return nil }
        let evidence: CardEvidence
        if let structure {
            evidence = .cameraStructure(structure)
        } else if volume.isDetachable, walk.videos > 0 {
            evidence = .detachableVideo(walk.videos)
        } else {
            return nil
        }
        return CardCandidate(volume: volume, files: walk.files,
                             bytes: walk.bytes, evidence: evidence)
    }

    /// What the walk found. A value rather than a triple: two of the three are
    /// what the prompt says and the fingerprint is made of, the third is what
    /// decides whether there is a prompt at all, and positional members read
    /// the same in whatever order they are in.
    struct CardContents: Sendable {
        var files = 0
        var bytes: Int64 = 0
        /// How many of the files a camera could have written (see
        /// `cameraVideoExtensions`) — the fallback branch's whole evidence.
        var videos = 0
    }

    /// The camera folder this volume's root matches, if any.
    nonisolated static func matchedStructure(at url: URL,
                                             root: Set<String>) -> String? {
        for nested in nestedCameraFolders {
            let parts = nested.split(separator: "/").map(String.init)
            guard let parent = parts.first, let child = parts.last,
                  root.contains(parent.lowercased()) else { continue }
            let inside = (try? FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent(parent).path)) ?? []
            if inside.contains(where: { $0.caseInsensitiveCompare(child)
                == .orderedSame }) {
                return nested
            }
        }
        // `PRIVATE` on its own proves nothing — it only counted through the
        // nested pass above.
        return cameraFolders.first {
            $0 != "PRIVATE" && root.contains($0.lowercased())
        }
    }

    /// Walk the tree: how many files, how many bytes, how many of them video.
    ///
    /// Hidden files are counted, because an offload copies them (the camera's own
    /// index files live there) and a fingerprint that ignored them would miss a
    /// card whose only change was one.
    nonisolated static func measure(_ root: URL) -> CardContents {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true })
        else { return CardContents() }
        var found = CardContents()
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            // Past the cap it is not a card at all — an empty result is how
            // `inspect` is told to leave this volume alone.
            if seen > entryCap { return CardContents() }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.files += 1
            found.bytes += Int64(values?.fileSize ?? 0)
            if cameraVideoExtensions.contains(url.pathExtension.lowercased()) {
                found.videos += 1
            }
        }
        return found
    }
}
