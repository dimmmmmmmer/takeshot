import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **The markers flagged on set, carried into the proxy as CHAPTERS** (owner:
/// "ого я не знал что так можно, конечно давай прокинем").
///
/// A marker has always reached post as a row in a sidecar and a line on the
/// shift report — both of which an assistant reads and types in. A chapter is
/// the same moment in the FILE: the proxy's scrub bar grows a menu, and an
/// editor lands on the frame somebody called out.
///
/// Read back through AVFoundation's own chapter reader rather than by
/// inspecting the track: what has to hold is that a player finds these, and
/// the track reference plus the sample layout is exactly the pair that can be
/// individually plausible and jointly unreadable.
///
/// **A time limit for `DailiesTimecodeTrackTests`' reason**: a writer input
/// with no samples holds every other input back for ever, so the failure mode
/// of getting this wrong is a HANG rather than a wrong file.
@Suite(.timeLimit(.minutes(1))) struct DailiesChapterTrackTests {
    /// The proxy's chapter list, as any player would read it.
    private func chapters(of url: URL) async throws
        -> [(title: String, start: Double)] {
        let asset = AVURLAsset(url: url)
        let locales: [Locale] = try await asset.load(.availableChapterLocales)
        let groups: [AVTimedMetadataGroup]
        if let locale = locales.first {
            groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [])
        } else {
            groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: ["en"])
        }
        var out: [(String, Double)] = []
        for group in groups {
            let titles = group.items.filter {
                $0.commonKey == .commonKeyTitle
            }
            let value = try await titles.first?.load(.stringValue)
            out.append((value ?? "", group.timeRange.start.seconds))
        }
        return out
    }

    private func rendered(markers: [TakeMarker], frames: Int = 50,
                          named name: String) async throws -> URL {
        let root = try DailiesRig.scratch()
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("\(name).mov"), frames: frames)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source, markers: markers)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        return try #require(report.items.first?.output,
                            "the take produced no daily")
    }

    /// The whole point: a flag on set is a chapter in the proxy, at the frame
    /// it was dropped on and under the name it was given.
    @Test func theTakesMarkersBecomeChaptersInTheProxy() async throws {
        let daily = try await rendered(
            markers: [TakeMarker(seconds: 0.4, note: "focus"),
                      TakeMarker(seconds: 1.2, note: "boom in frame")],
            named: "A001C001")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        let list = try await chapters(of: daily)
        #expect(list.count == 2, "the proxy carries \(list.count) chapters")
        #expect(list.map(\.title) == ["focus", "boom in frame"])
        #expect(abs(list[0].start - 0.4) < 0.05, "\(list[0].start)")
        #expect(abs(list[1].start - 1.2) < 0.05, "\(list[1].start)")
    }

    /// A note in the operator's own language survives the sample layout.
    ///
    /// This is the assertion the `encd` atom exists for: without it a reader
    /// is entitled to read MacRoman, and the ENGLISH notes look right while
    /// every Cyrillic one comes back as mojibake — in a file nobody re-checks.
    @Test func aNoteInAnotherAlphabetSurvives() async throws {
        let daily = try await rendered(
            markers: [TakeMarker(seconds: 0.5, note: "брак — микрофон в кадре")],
            named: "A001C002")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        let list = try await chapters(of: daily)
        #expect(list.map(\.title) == ["брак — микрофон в кадре"])
    }

    /// A marker with no note is still a moment somebody flagged, and it lands
    /// under its own timecode — the same pair the shift report's marker line
    /// prints, so one flag reads the same in both.
    @Test func aMarkerWithNoNoteIsNamedByItsTimecode() async throws {
        let daily = try await rendered(
            markers: [TakeMarker(seconds: 0.5,
                                 timecodeText: "10:00:00:12")],
            named: "A001C003")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(try await chapters(of: daily).map(\.title) == ["10:00:00:12"])
    }

    /// A take nobody flagged gets NO chapter track, rather than one entry
    /// named after the file: a scrub bar that grows an empty menu is a worse
    /// answer than one that does not grow a menu.
    @Test func aTakeWithNoMarkersGetsNoChapterTrack() async throws {
        let daily = try await rendered(markers: [], named: "A001C004")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        let asset = AVURLAsset(url: daily)
        #expect(try await asset.load(.availableChapterLocales).isEmpty)
        #expect(try await asset.tracks(ofType: .text).isEmpty)
        // …and the picture and sound are untouched by its absence
        #expect(try await !asset.tracks(ofType: .video).isEmpty)
    }

    /// Markers arrive in whatever order the sidecar held them; chapters are a
    /// timeline and have to be in time order or a reader takes the list as it
    /// finds it and places the second one before the first.
    @Test func markersOutOfOrderAreSortedIntoATimeline() async throws {
        let daily = try await rendered(
            markers: [TakeMarker(seconds: 1.2, note: "late"),
                      TakeMarker(seconds: 0.4, note: "early")],
            named: "A001C005")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(try await chapters(of: daily).map(\.title) == ["early", "late"])
    }

    /// The picture is what a daily is for: a chapter track must not cost the
    /// proxy its length, its sound or its timecode.
    @Test func theChaptersCostThePictureNothing() async throws {
        let daily = try await rendered(
            markers: [TakeMarker(seconds: 0.4, note: "focus")],
            frames: 50, named: "A001C006")
        defer { try? FileManager.default.removeItem(
            at: daily.deletingLastPathComponent().deletingLastPathComponent()) }
        let asset = AVURLAsset(url: daily)
        let video: AVAssetTrack = try #require(
            try await asset.tracks(ofType: .video).first)
        let seconds = try await video.load(.timeRange).duration.seconds
        #expect(abs(seconds - 2) < 0.1, "the picture is \(seconds)s long")
        #expect(try await !asset.tracks(ofType: .timecode).isEmpty,
                "the chapter track cost the proxy its timecode")
    }

    // MARK: - the bytes

    /// The length is the TEXT's byte count and not the sample's: a reader
    /// takes that many bytes and then looks for atoms in what is left, so
    /// counting the atom in swallows it and truncates the title.
    @Test func theSampleStatesTheTextsOwnLength() {
        let data: Data = ChapterTrack.data(for: "focus")
        #expect(data.count == 2 + 5 + 12)
        #expect(Int(data[0]) << 8 | Int(data[1]) == 5)
        #expect(String(data: data[2..<7], encoding: .utf8) == "focus")
        // …and the trailing atom says UTF-8
        #expect(String(data: data[11..<15], encoding: .ascii) == "encd")
        #expect(data.suffix(4) == Data([0x00, 0x00, 0x01, 0x00]))
    }

    /// A title longer than the count can express is cut rather than written
    /// with a length that means something else entirely.
    @Test func anAbsurdlyLongTitleIsCutToWhatTheCountCanSay() {
        let data: Data = ChapterTrack.data(
            for: String(repeating: "a", count: 100_000))
        #expect(Int(data[0]) << 8 | Int(data[1]) == Int(UInt16.max))
        #expect(data.count == 2 + Int(UInt16.max) + 12)
    }
}
