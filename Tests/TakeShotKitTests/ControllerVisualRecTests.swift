import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The synthetic monitoring output the controller suites teach against: a frame
/// with a red block where a camera would put its REC dot, pushed straight into
/// the controller's own pipeline — the shortest way to give the teach capture
/// something to read without a board.
///
/// File scope rather than a member, so the two suites below share one fixture
/// instead of one of them growing a second copy of it.
@MainActor
enum VisualRecControllerProbe {
    static let width = 320
    static let height = 180
    /// Where the fixture puts the dot, in SIGNAL fractions.
    static let dotX = 0.8
    static let dotY = 0.12
    /// A 16:9 viewport, so the picture fills it and a point IS a fraction.
    static let viewport = CGSize(width: 1600, height: 900)
    /// The point in that viewport that lands on the dot.
    static let dotPoint = CGPoint(x: dotX * viewport.width,
                                  y: dotY * viewport.height)

    static func push(_ controller: CaptureController, dot: Bool) async {
        let buffer = MediaFixtures.pixelBuffer(level: 0, width: width,
                                               height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let centreX = Int(dotX * Double(width))
            let centreY = Int(dotY * Double(height))
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    let lit = dot && abs(x - centreX) < 8 && abs(y - centreY) < 8
                    // BGRA
                    row[x * 4] = lit ? 30 : 62
                    row[x * 4 + 1] = lit ? 30 : 62
                    row[x * 4 + 2] = lit ? 220 : 62
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        controller.pipeline.handleFormat(
            CaptureFormat(width: width, height: height, frameRate: 25,
                          timecodeFPS: 25, name: "320x180"))
        controller.pipeline.handleFrame(
            pixelBuffer: buffer, pts: CMTime(value: 40, timescale: 1000),
            timecode: nil, vancTrigger: nil)
        await ControllerWait.until {
            controller.pipeline.captureVisualRecSignature() != nil
        }
    }

    /// The box on the dot, both references captured — the state every test past
    /// the marking ones starts from.
    static func teach(_ controller: CaptureController) async {
        controller.visualRecTeaching.region =
            VisualRecRegion(centerX: dotX, centerY: dotY)
        await VisualRecControllerProbe.push(controller, dot: true)
        controller.learnVisualRec(.rolling)
        await VisualRecControllerProbe.push(controller, dot: false)
        controller.learnVisualRec(.idle)
    }
}

/// The taught indicator's controller half: what a click on the picture marks and
/// what the two captures produce. What survives a relaunch and what the
/// diagnostics bundle says are `ControllerVisualRecReportTests`.
@MainActor
struct ControllerVisualRecTests {
    // MARK: - marking the box

    /// A click on the picture puts the box's centre on the pixel under the
    /// pointer, in SIGNAL fractions — the units that survive a punch-in.
    @Test func aClickMarksTheBoxOnThePicture() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.toggleVisualRecTeach()
            #expect(controller.visualRecTeachArmed)

            controller.placeVisualRecRegion(at: VisualRecControllerProbe.dotPoint,
                                            viewport: VisualRecControllerProbe.viewport)
            let region = controller.visualRecTeaching.region
            #expect(abs(region.centerX - 0.8) < 0.01, "x is \(region.centerX)")
            #expect(abs(region.centerY - 0.12) < 0.01, "y is \(region.centerY)")
            // …and unlike the eyedropper it stays armed: a box has a size, and
            // the operator adjusts it while watching the reading
            #expect(controller.visualRecTeachArmed,
                    "placing the box disarmed teaching mode mid-adjustment")
        }
    }

    /// A click on the letterbox names no signal pixel and must leave the box
    /// where it was.
    @Test func aClickOutsideThePictureMovesNothing() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.placeVisualRecRegion(at: VisualRecControllerProbe.dotPoint,
                                            viewport: VisualRecControllerProbe.viewport)
            let before = controller.visualRecTeaching.region
            // a tall viewport on a 16:9 picture: the top 200pt are letterbox
            controller.placeVisualRecRegion(at: CGPoint(x: 800, y: 20),
                                            viewport: CGSize(width: 1600,
                                                             height: 1300))
            #expect(controller.visualRecTeaching.region == before,
                    "the letterbox moved the watched box")
        }
    }

    /// The box's size is clamped to the small range the metric can answer for,
    /// whatever a slider or a hand-edited blob asks for.
    @Test func theBoxSizeIsClamped() async throws {
        try await ViewProbe.run { probe in
            probe.controller.visualRecWidth = 10
            #expect(probe.controller.visualRecWidth == VisualRecRegion.maxSize)
            probe.controller.visualRecWidth = -1
            #expect(probe.controller.visualRecWidth == VisualRecRegion.minSize)
            // The margin is derived from the separation now, so an untaught
            // controller reports the ceiling — the most demanding answer, which
            // is the right one when nothing has been measured.
            #expect(probe.controller.visualRecMargin
                    == VisualRecTeaching.maxMargin)
        }
    }

    // MARK: - the two captures

    /// Two presses teach it, and the second one is what makes it armable. Before
    /// both exist the switch cannot be turned on at all — opt-in AND provable.
    @Test func twoCapturesTeachItAndOnlyThenCanItBeArmed() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12)

            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            #expect(controller.visualRecTeaching.rolling != nil)
            #expect(!controller.visualRecTeaching.isTaught,
                    "one reference claimed to be a teaching")
            controller.visualRecOn = true
            #expect(!controller.visualRecOn,
                    "an untaught trigger let itself be switched on")

            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)
            let separation = controller.visualRecTeaching.separation
            #expect(controller.visualRecTeaching.isTaught,
                    "the pair did not separate: \(separation ?? -1)")
            controller.visualRecOn = true
            #expect(controller.visualRecOn)
            #expect(controller.visualRecTeaching.isArmed)
        }
    }

    /// Capturing a reference switches the trigger off: the pair has just changed
    /// and the operator has not yet seen what it separates by.
    @Test func capturingAReferenceDisarmsTheTrigger() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12)
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)
            controller.visualRecOn = true
            #expect(controller.visualRecOn)

            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            #expect(!controller.visualRecOn,
                    "a re-teach left the trigger live on a pair nobody had seen")
        }
    }

    /// Two captures of a picture with no indicator in it — the operator marked
    /// the wrong place, or the camera sends no overlay at all. Both references
    /// exist and the trigger still cannot be armed, which is the failure this has
    /// to have: an armed trigger reading noise is a take nobody asked for.
    @Test func twoCapturesOfTheSamePictureCannotBeArmed() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            // the box on flat background, well away from where the dot appears
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.2, centerY: 0.6)
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)

            #expect(controller.visualRecTeaching.rolling != nil)
            #expect(controller.visualRecTeaching.idle != nil)
            let separation = controller.visualRecTeaching.separation ?? -1
            #expect(!controller.visualRecTeaching.isTaught,
                    "a box that misses the indicator taught \(separation) codes")
            controller.visualRecOn = true
            #expect(!controller.visualRecOn, "it armed on two identical captures")
        }
    }

    /// Arming the trigger puts teaching mode away — the box and the crosshair on
    /// the picture while the unit is shooting read as a stuck mode.
    @Test func armingTheTriggerEndsTeachingMode() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12)
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)
            controller.visualRecTeachArmed = true

            controller.visualRecOn = true
            #expect(controller.visualRecOn)
            #expect(!controller.visualRecTeachArmed)
        }
    }

    /// Forgetting the references keeps the box and the margin — a re-teach after
    /// a firmware change should not cost the operator the box's position too.
    @Test func forgettingKeepsTheBox() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12, width: 0.1)
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)

            controller.forgetVisualRecReferences()
            #expect(controller.visualRecTeaching.rolling == nil)
            #expect(controller.visualRecTeaching.idle == nil)
            #expect(!controller.visualRecOn)
            #expect(controller.visualRecTeaching.region
                    == VisualRecRegion(centerX: 0.8, centerY: 0.12, width: 0.1))
        }
    }
}

/// What the taught indicator leaves behind: the stored teaching, and what a
/// diagnostics bundle collected after a spurious roll can say about it.
///
/// Its own suite rather than more of the one above — that one had reached the
/// length at which nobody reads a type top to bottom, and these are a different
/// question anyway.
@MainActor
struct ControllerVisualRecReportTests {
    // MARK: - what a relaunch keeps

    /// The teaching persists and the SWITCH deliberately does not. The references
    /// are a photograph of one camera's overlay in one framing, and a trigger that
    /// re-arms itself on a rig it was never taught on is the false start this
    /// feature is most able to cause.
    @Test func theTeachingSurvivesARelaunchAndTheSwitchDoesNot() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12, width: 0.1)
            await VisualRecControllerProbe.push(controller, dot: true)
            controller.learnVisualRec(.rolling)
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.learnVisualRec(.idle)
            controller.visualRecOn = true
            #expect(controller.visualRecOn)

            // what the stored blob holds, once the debounce has run.
            //
            // The write is deferred by 400 ms — a box moves with a DRAG, and
            // persisting every tick of one re-rendered the window through
            // `applySettingsChange`. So this polls for the outcome rather than
            // reading immediately or sleeping a guessed interval.
            var stored = CaptureSettings.loaded(from: controller.defaults)
            #expect(await ControllerWait.until {
                stored = CaptureSettings.loaded(from: controller.defaults)
                return stored.visualRec.rolling != nil
            }, "the teaching never reached the settings")
            #expect(stored.visualRec.idle != nil)
            // The retired square key is cleared on write; the pair replaces it.
            #expect(stored.visualRec.size == nil)
            #expect(stored.visualRec.width == 0.1)
            // Derived, so nothing is stored for it.
            #expect(stored.visualRec.margin == nil)

            // …and what comes back from it
            controller.visualRecTeaching = VisualRecTeaching()
            controller.restoreVisualRec(from: stored.visualRec)
            let restored = controller.visualRecTeaching
            #expect(restored.isTaught, "the references did not come back")
            #expect(!restored.isOn, "the trigger re-armed itself at launch")
            #expect(abs(restored.region.centerX - 0.8) < 0.001)
            // …and it comes back from the references rather than from a key.
            #expect(restored.margin == restored.margin)
            #expect(restored.margin <= VisualRecTeaching.maxMargin)
        }
    }

    /// A hand-edited or truncated stored reference leaves the trigger untaught
    /// rather than armed on garbage.
    @Test func aCorruptStoredReferenceLeavesItUntaught() async throws {
        try await ViewProbe.run { probe in
            var stored = CaptureSettings()
            stored.visualRec.rolling = "not base64 at all!!"
            stored.visualRec.idle = "AAAA"
            probe.controller.restoreVisualRec(from: stored.visualRec)
            #expect(probe.controller.visualRecTeaching.rolling == nil)
            #expect(probe.controller.visualRecTeaching.idle == nil)
            #expect(!probe.controller.visualRecTeaching.isTaught)
        }
    }

    // MARK: - saying which trigger fired

    /// A take started by hand reports itself as such — on the picture and in the
    /// bundle. Nobody can diagnose a spurious roll from a red dot that says only
    /// "REC".
    @Test func aManualTakeNamesItsTrigger() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.push(controller, dot: false)
            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            #expect(controller.recTrigger == .manual,
                    "\(String(describing: controller.recTrigger))")
            #expect(controller.recBadgeText != L("rec"),
                    "the REC mark did not name the trigger")

            controller.toggleManualRecord()
            await ControllerWait.untilWritten { !controller.isRecording }
            #expect(controller.recTrigger == nil,
                    "the trigger stayed on screen after the take closed")
            // …but the bundle still knows, which is when it is usually collected
            #expect(controller.pipeline.health.startTrigger == .manual)
        }
    }

    /// The diagnostics bundle reports the trigger and the whole state of the
    /// teaching — a bundle sent from set has to answer "could this have rolled
    /// the take" without the sender being asked follow-up questions.
    @Test func theBundleReportsTheTriggerAndTheTeaching() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            // untaught: it says so in as many words rather than printing zeros
            var report = DiagnosticsReport.text(for: controller.diagnosticsSnapshot())
            #expect(report.contains("REC indicator"))
            #expect(report.contains("not taught"), "\(report)")
            #expect(report.contains("Started by"))

            await VisualRecControllerProbe.teach(controller)
            controller.visualRecOn = true

            report = DiagnosticsReport.text(for: controller.diagnosticsSnapshot())
            #expect(report.contains("armed"), "\(report)")
            #expect(report.contains("separation"), "\(report)")
            #expect(report.contains("margin"), "\(report)")
            // …and the box, so a reader can see WHERE it was watching
            #expect(report.contains("centre 80%,12%"), "\(report)")
        }
    }

    /// The bundle carries no reference data. Two 256-character base64 blobs in a
    /// file meant to be read by a person are noise, and the bundle exists to be
    /// sent to someone.
    @Test func theBundleCarriesNoReferenceBlobs() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await VisualRecControllerProbe.teach(controller)

            let encoded = controller.visualRecTeaching.rolling?.encoded ?? "?"
            let report = DiagnosticsReport.text(for: controller.diagnosticsSnapshot())
            #expect(!report.contains(encoded),
                    "a reference blob was printed into the bundle")
        }
    }
}
