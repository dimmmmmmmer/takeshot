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

    /// **HEVC has its own family**, and it is not H.264's.
    ///
    /// The picker used to offer one list to both codecs, so an HEVC stream
    /// could be asked for "High", which HEVC does not have (owner: "в энкодере
    /// для hevc что значит profile high вообще? там есть такое понятие?").
    /// HEVC's three are Main, Main 10 and Main 4:2:2 10, and each has to reach
    /// VideoToolbox as its own level; a profile from the other family resolves
    /// to Main rather than building a session that refuses.
    @Test func hevcAsksForItsOwnProfileLevels() {
        var configuration = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 25,
            bitsPerSecond: 6_000_000)
        configuration.codec = .hevc
        let expected: [SRTEncoderProfile: CFString] = [
            .main: kVTProfileLevel_HEVC_Main_AutoLevel,
            .main10: kVTProfileLevel_HEVC_Main10_AutoLevel,
            .main422Ten: kVTProfileLevel_HEVC_Main42210_AutoLevel,
            // not HEVC's — resolved rather than refused
            .baseline: kVTProfileLevel_HEVC_Main_AutoLevel,
            .high: kVTProfileLevel_HEVC_Main_AutoLevel,
        ]
        for (profile, level) in expected {
            configuration.profile = profile
            #expect(SRTVideoEncoder.profileLevel(configuration) == level,
                    Comment(rawValue: "HEVC \(profile) asked for the wrong level"))
        }
        #expect(SRTEncoderProfile.offered(for: .hevc)
            == [.main, .main10, .main422Ten])
        #expect(SRTEncoderProfile.offered(for: .h264)
            == [.baseline, .main, .high])
    }

    /// **And the profile actually REACHES the session.**
    ///
    /// It did not, for the whole life of the feature: the properties
    /// dictionary hard-coded `kVTProfileLevel_H264_High_AutoLevel` while
    /// `profileLevel(_:)` sat beside it, written and tested and never called.
    /// The suite exercised the helper and nothing exercised the CALL SITE, so
    /// a picker with five rows moved nothing at all and every HEVC session was
    /// asked for an H.264 level. This asks the properties, not the helper.
    @Test func theChosenProfileIsWhatTheSessionIsTold() {
        var configuration = SRTVideoEncoder.Configuration(
            width: 1920, height: 1080, framesPerSecond: 25,
            bitsPerSecond: 6_000_000)
        for (codec, profile, level) in [
            (SRTVideoCodec.h264, SRTEncoderProfile.baseline,
             kVTProfileLevel_H264_Baseline_AutoLevel),
            (.h264, .main, kVTProfileLevel_H264_Main_AutoLevel),
            (.hevc, .main10, kVTProfileLevel_HEVC_Main10_AutoLevel),
            (.hevc, .main422Ten, kVTProfileLevel_HEVC_Main42210_AutoLevel),
        ] {
            configuration.codec = codec
            configuration.profile = profile
            // `CFEqual` rather than a cast: the dictionary's values are
            // `CFTypeRef`, and a conditional downcast of one to `CFString`
            // always succeeds as far as the compiler is concerned — so the
            // cast is a warning and the comparison it enables is a lie.
            let told = SRTVideoEncoder.properties(configuration)[
                kVTCompressionPropertyKey_ProfileLevel]
            #expect(told.map { CFEqual($0, level) } == true, Comment(rawValue: """
                \(codec) \(profile) told the session \(String(describing: told))
                """))
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
