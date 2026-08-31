import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A still lands on the disk, and the write does not happen on the actor.**
///
/// The encode was carefully moved off the main actor and then handed back to do
/// the blocking part — `createDirectory` and `write` against the record root,
/// which on set is an external SSD or a share. A stall there is the whole UI
/// stopped, REC included, for as long as the volume takes to answer.
@Suite @MainActor struct ControllerGrabSaveTests {
    private func buffer() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &made)
        return try #require(made)
    }

    @Test func agrabbedStillIsWrittenAndAnnounced() async throws {
        try await ControllerHarness.run { controller, root in
            controller.settings.naming.projectName = "TEST"
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("clip.mov")
            controller.playbackTap.attachStill(try buffer())

            controller.grabFrame()

            let announced = await ControllerWait.until {
                controller.lastNotice?.contains(".png") == true
            }
            #expect(announced, "the still never said it had been saved")

            let files = try FileManager.default
                .contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".png") }
            #expect(files.count == 1, "expected one still on the disk: \(files)")
            let written = try #require(files.first)
            #expect(written.hasPrefix("TEST_"),
                    "the still was not named from the project: \(written)")
            let bytes = try Data(contentsOf: root.appendingPathComponent(written))
            #expect(bytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
                    "the file on the disk is not a PNG")
        }
    }

    /// A destination that refuses the write says so, rather than announcing a
    /// still that is not there.
    @Test func awriteThatFailsIsReportedAndNotAnnounced() async throws {
        try await ControllerHarness.run { controller, root in
            controller.viewerMode = .playback
            controller.playbackURL = root.appendingPathComponent("clip.mov")
            controller.playbackTap.attachStill(try buffer())
            try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                  ofItemAtPath: root.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root.path)
            }

            controller.grabFrame()

            let told = await ControllerWait.until { controller.lastError != nil }
            #expect(told, "a still that could not be written said nothing")
            #expect(controller.lastNotice?.contains(".png") != true,
                    "a still that was never written was announced as saved")
        }
    }
}
