import Foundation
import Testing

@testable import TakeShotKit

/// **A destination is named by its DISK, and a run is logged by its PATH.**
///
/// Two of the same complaint: the offload sheet named a destination
/// `/Volumes/punkt_backup2_main/yep` "yep", and the run log named the same
/// place "yep" too — the folder, which the path underneath already says (owner:
/// "название источника должно быть названием диска, а не папки; имя папки мы
/// итак видим в path" and "recent offloads должен показывать paths, а не имена
/// скопированных папок").
///
/// What an operator reads off a destination at a glance is WHICH DRIVE, because
/// that is the thing they plug in, unplug and hand over — and two shuttle
/// drives with a `DAILIES` folder each produced two log rows that read
/// identically.
struct OffloadRowNamingTests {
    /// The volume, not the folder. Asked of a real path on this machine: the
    /// rule is a filesystem question and a made-up URL cannot answer it.
    @Test func aDestinationIsNamedByItsVolume() throws {
        let root = URL(fileURLWithPath: "/")
        let volume = OffloadVolumeFacts.name(of: root)
        #expect(!volume.isEmpty)
        #expect(volume != "/", "the root fell back to its own path")

        // A folder on that volume answers with the SAME name — which is the
        // whole change: it used to answer with the folder's.
        let nested = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nested) }
        #expect(OffloadVolumeFacts.name(of: nested)
                != nested.lastPathComponent,
                "a folder is still named after itself rather than its disk")
    }

    /// A path that names no volume at all still says something — the fallback
    /// is what kept this from being a crash on a destination that was unplugged
    /// between the list being drawn and this line running.
    @Test func aPathWithNoVolumeFallsBackToItsLastComponent() {
        let gone = URL(fileURLWithPath: "/Volumes/NoSuchDisk-\(UUID().uuidString)/DAY_03")
        #expect(OffloadVolumeFacts.name(of: gone) == "DAY_03")
    }

    /// One destination is logged by its full path; several stay a count,
    /// because four paths on one line is worth less than the number.
    @Test func theRunLogNamesTheWholePath() throws {
        // Decoded rather than built: the record's only initializer takes a
        // finished `OffloadReport`, and what is under test is how a stored row
        // READS — which is exactly what a decode gives.
        func record(_ destinations: [String]) throws -> OffloadRunRecord {
            let fields: [String: Any] = [
                "id": UUID().uuidString, "date": 0,
                "sourcePath": "/Volumes/CARD_A001",
                "destinationPaths": destinations,
                "verdict": "verified", "files": 12, "filesVerified": 12,
                "bytes": 1_000,
            ]
            let data = try JSONSerialization.data(withJSONObject: fields)
            return try JSONDecoder().decode(OffloadRunRecord.self, from: data)
        }

        let single = try record(["/Volumes/SSD_1/DAY_03"])
        #expect(OffloadHistoryList.headline(single)
                == "CARD_A001 → /Volumes/SSD_1/DAY_03")

        let several = try record(["/Volumes/SSD_1/DAY_03",
                                  "/Volumes/SSD_2/DAY_03"])
        #expect(OffloadHistoryList.headline(several)
                == "CARD_A001 → " + L("offload_history_copies", 2))
    }
}
