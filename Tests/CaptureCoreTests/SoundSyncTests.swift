import Foundation
import Testing

@testable import CaptureCore

/// **Which of the recordist's files belong to a take.**
///
/// The everyday description is "the same timecode", and the rule cannot be
/// that: a recordist rolls before the camera and stops after it, and on many
/// units the sound runs continuously across a setup. These hold the rule that
/// works on a real day — overlap, in both directions, with the offset exact.
@Suite struct SoundSyncTests {
    private func sound(at start: Double?, seconds: Double,
                       named name: String = "A001.wav")
        -> BroadcastWaveFacts {
        BroadcastWaveFacts(
            url: URL(fileURLWithPath: "/tmp/\(name)"), sampleRate: 48_000,
            channelCount: 2, frameCount: Int(seconds * 48_000),
            startSecondsSinceMidnight: start)
    }

    /// The ordinary case: sound rolled first, stopped later, and the take sits
    /// inside it. The offset is where the picture starts in the file.
    @Test func aFileTheTakeSitsInsideMatchesWithTheOffsetItStartsAt() {
        let matches = SoundSync.matches(
            pictureStart: 36_010, pictureDuration: 20,
            in: [sound(at: 36_000, seconds: 60)])
        #expect(matches.count == 1)
        #expect(matches.first?.offsetIntoSound == 10, """
            the take starts \(String(describing: matches.first?.offsetIntoSound))s \
            into the file, not 10
            """)
    }

    /// One file, several takes: a running safety belongs to every take it
    /// covers, and a rule that paired one-to-one would drop all but one.
    @Test func oneLongFileBelongsToEveryTakeItCovers() {
        let safety = sound(at: 36_000, seconds: 600)
        for start in [36_010.0, 36_200.0, 36_500.0] {
            let matches = SoundSync.matches(pictureStart: start,
                                            pictureDuration: 20, in: [safety])
            #expect(matches.count == 1,
                    "the take at \(start) found \(matches.count) files")
        }
    }

    /// …and one take, several files: the per-take file AND the safety.
    @Test func aTakeCoveredByTwoFilesGetsBoth() {
        let matches = SoundSync.matches(
            pictureStart: 36_010, pictureDuration: 20,
            in: [sound(at: 36_000, seconds: 600, named: "safety.wav"),
                 sound(at: 36_008, seconds: 30, named: "take.wav")])
        #expect(matches.count == 2, "one take found \(matches.count) files")
    }

    /// A file that merely touches the take is not this take's sound: the
    /// recordist stopped as the camera rolled, or the next slate started on
    /// the tail.
    @Test func aFileThatBarelyTouchesTheTakeDoesNotCount() {
        let brushing = sound(at: 36_009.5, seconds: 1)
        let matches = SoundSync.matches(pictureStart: 36_010,
                                        pictureDuration: 20, in: [brushing])
        #expect(matches.isEmpty, """
            half a second of overlap counted as this take's sound
            """)
    }

    /// A file with no `bext` matches nothing. It must never read as midnight,
    /// which would line it up with every take shot in the first minutes of a
    /// day and with nothing else.
    @Test func aFileWithNoTimecodeMatchesNothing() {
        let matches = SoundSync.matches(
            pictureStart: 30, pictureDuration: 20,
            in: [sound(at: nil, seconds: 600)])
        #expect(matches.isEmpty, "a file with no timecode was matched")
    }

    /// **Midnight.** A take that rolled at 23:59:50 and a file that rolled at
    /// 23:59:45 are five seconds apart, not twenty-three hours and change —
    /// the same wrap the marker exporter already makes for the same reason.
    @Test func theClockFoldsAtMidnightRatherThanRunningBackwards() {
        // picture 00:00:05, sound started at 23:59:55
        let matches = SoundSync.matches(
            pictureStart: 5, pictureDuration: 20,
            in: [sound(at: 86_395, seconds: 60)])
        #expect(matches.count == 1, "the file across midnight was not matched")
        #expect(matches.first?.offsetIntoSound == 10, """
            the take lands \(String(describing: matches.first?.offsetIntoSound))s \
            into a file that started ten seconds before it
            """)
    }

    /// …and in the other direction: a file that starts after midnight under a
    /// take that started before it.
    @Test func theWrapWorksBothWays() {
        let matches = SoundSync.matches(
            pictureStart: 86_390, pictureDuration: 30,
            in: [sound(at: 5, seconds: 60)])
        #expect(matches.count == 1)
        #expect(matches.first?.offsetIntoSound == -15, """
            the offset is \(String(describing: matches.first?.offsetIntoSound)) \
            — the sound starts fifteen seconds INTO the take, so it is negative
            """)
    }
}
