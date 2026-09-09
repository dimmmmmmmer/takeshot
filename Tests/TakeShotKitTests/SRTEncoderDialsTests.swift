import CaptureCore
import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import TakeShotKit

/// **The encoder's five dials** (owner: "у энкодера там профиль выбрать типа,
/// абр цбр, кейфреймы б фреймы, в общем что посчитаешь нужным для кастомизации
/// но чтобы не перегружать пользователя").
///
/// Every one of them defaults to what this app has always streamed, so a
/// stream set up before they existed is byte-for-byte the stream it was.
@Suite struct SRTEncoderDialsTests {
    @Test func theDefaultsAreWhatTheAppAlwaysStreamed() {
        let settings = SRTSettings()
        #expect(settings.codecEffective == .h264)
        #expect(settings.profileEffective == .high)
        #expect(settings.rateControlEffective == .average)
        #expect(settings.keyframeSecondsEffective == 1)
        #expect(!settings.bFramesEffective)
        #expect(SRTVideoEncoder.Dials(settings) == SRTVideoEncoder.Dials())
    }

    /// A hand-edited blob naming something that is not a choice falls back
    /// rather than producing a session nobody asked for.
    @Test func nonsenseFallsBack() {
        var settings = SRTSettings()
        settings.codec = "AV1"
        settings.profile = "ultra"
        settings.rateControl = "vbr-ish"
        #expect(settings.codecEffective == .h264)
        #expect(settings.profileEffective == .high)
        #expect(settings.rateControlEffective == .average)
    }

    /// **The keyframe interval is held to a range a monitoring feed survives.**
    /// Under a second the link goes on parameter sets; over ten a director
    /// watching a frozen frame waits ten seconds for it to come back.
    @Test func theKeyframeIntervalIsHeldToItsRange() {
        var settings = SRTSettings()
        settings.keyframeSeconds = 0
        #expect(settings.keyframeSecondsEffective == 1)
        settings.keyframeSeconds = -4
        #expect(settings.keyframeSecondsEffective == 1)
        settings.keyframeSeconds = 900
        #expect(settings.keyframeSecondsEffective == 10)
        settings.keyframeSeconds = 4
        #expect(settings.keyframeSecondsEffective == 4)
    }

    /// Seconds become FRAMES for VideoToolbox, at the signal's own rate — the
    /// interval is a duration to the operator and a frame count to the encoder.
    @Test func secondsBecomeFramesAtTheSignalsRate() {
        var configuration = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 25,
            bitsPerSecond: 6_000_000)
        #expect(configuration.keyframeInterval == 25)
        configuration.keyframeSeconds = 4
        #expect(configuration.keyframeInterval == 100)
        configuration.framesPerSecond = 60
        #expect(configuration.keyframeInterval == 240)
        // …and a nonsense rate cannot produce an interval of zero, which
        // VideoToolbox reads as "every frame is a keyframe".
        configuration.framesPerSecond = 0
        configuration.keyframeSeconds = 0
        #expect(configuration.keyframeInterval >= 1)
    }

    /// **HEVC has no Baseline.** The two pickers are independent, so a stream
    /// asked for Baseline in HEVC gets Main rather than a session that refuses
    /// to build.
    @Test func hevcResolvesToItsOwnProfileFamily() {
        var configuration = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 25,
            bitsPerSecond: 6_000_000)
        configuration.codec = .hevc
        for profile in SRTEncoderProfile.allCases {
            configuration.profile = profile
            #expect(SRTVideoEncoder.profileLevel(configuration)
                == kVTProfileLevel_HEVC_Main_AutoLevel,
                    Comment(rawValue: "HEVC \(profile) resolved elsewhere"))
        }
    }

    @Test func eachH264ProfileAsksForItsOwnLevel() {
        var configuration = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 25,
            bitsPerSecond: 6_000_000)
        let expected: [SRTEncoderProfile: CFString] = [
            .baseline: kVTProfileLevel_H264_Baseline_AutoLevel,
            .main: kVTProfileLevel_H264_Main_AutoLevel,
            .high: kVTProfileLevel_H264_High_AutoLevel,
        ]
        for (profile, level) in expected {
            configuration.profile = profile
            #expect(SRTVideoEncoder.profileLevel(configuration) == level,
                    Comment(rawValue: "\(profile) asked for the wrong level"))
        }
    }

    /// The dials are part of the session's identity, so a change has to be
    /// visible as a change — that is what makes the encoder rebuild rather
    /// than go on streaming the old settings.
    @Test func movingADialIsADifferentConfiguration() {
        let base = SRTVideoEncoder.Dials()
        for mutate in [{ (dials: inout SRTVideoEncoder.Dials) in
                            dials.codec = .hevc },
                       { $0.profile = .main },
                       { $0.rateControl = .constant },
                       { $0.keyframeSeconds = 4 },
                       { $0.allowBFrames = true }] {
            var moved = base
            mutate(&moved)
            #expect(moved != base, "a dial moved without changing the dials")
        }
    }
}
