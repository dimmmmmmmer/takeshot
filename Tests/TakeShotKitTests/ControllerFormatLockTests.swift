import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The codec and the record folder moved into the footer (owner item 48), which
/// puts both one click away from an operator watching a take run. Both are
/// therefore locked while a take records: the writer was created with the codec
/// and is writing into that folder, so neither change can reach the file — and
/// switching the folder mid-take resets the library the take is about to join.
@Suite @MainActor struct ControllerFormatLockTests {
    @Test func theRecordingFormatIsOpenWhileIdle() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.isRecording)
            #expect(controller.canChangeRecordingFormat)

            controller.isCapturing = true // rolling, not recording
            #expect(controller.canChangeRecordingFormat)
        }
    }

    @Test func theRecordingFormatIsLockedWhileATakeRecords() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.isCapturing = true
            controller.isRecording = true

            #expect(!controller.canChangeRecordingFormat)

            controller.isRecording = false
            #expect(controller.canChangeRecordingFormat,
                    "the lock outlived the take")
        }
    }

    /// The picker writes straight into settings, so the lock is what stands
    /// between a take and a codec it was not written in. This pins that the
    /// setting the footer offers is the one the writer reads.
    @Test func theCodecTheFooterOffersIsTheOneTakesAreWrittenIn() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.codec = .proResHQ
            #expect(controller.settings.codec == .proResHQ)
            #expect(CaptureSettings.loaded(from: controller.defaults).codec
                == .proResHQ)
            // every codec has a short name for the footer's narrow label, and
            // none of them is empty
            for codec in CaptureCodec.allCases {
                let short = FooterCodecMenu.shortName(codec)
                #expect(!short.isEmpty)
                #expect(short.count <= codec.rawValue.count)
            }
        }
    }
}
