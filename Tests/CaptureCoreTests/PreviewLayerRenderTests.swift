import CoreImage
import CoreVideo
import Metal
import QuartzCore
import Testing

@testable import CaptureCore

/// The layer's draw path, rendering for real.
///
/// `PreviewSinkRegistryTests` deliberately stays clear of presenting anything;
/// this suite is the opposite end — an off-screen `MetalPreviewLayer` with a
/// real device and real drawables. It is guarded on a Metal device even though
/// CI has one, because a machine without a GPU short-circuits every one of these
/// paths and a suite that silently asserted nothing would be worse than a
/// skipped one.
///
/// What is pinned here is the part that made the on-set bugs: the draw runs off
/// the caller's thread (`nextDrawable()` parks for ~1 s on an occluded window,
/// long enough to freeze the REC button mid-take), the newest frame wins, a
/// resize while paused re-renders instead of stretching the old drawable, and a
/// signal loss blanks the surface instead of freezing the last frame.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil,
                "no Metal device on this machine"))
struct PreviewLayerRenderTests {
    // MARK: - fixtures

    private func makeLayer(size: CGSize = CGSize(width: 128, height: 64))
        -> MetalPreviewLayer {
        let layer = MetalPreviewLayer()
        layer.setDrawableSize(size)
        return layer
    }

    /// Everything the layer does is queued on its own redraw queue; draining it
    /// is how a test waits without a sleep.
    private func drain(_ layer: MetalPreviewLayer) {
        layer.redrawQueue.sync {}
    }

    /// The renderer holds `renderLock` across the GPU work and writes these
    /// under it; a test reads them the same way rather than racing the queue.
    private func state(of layer: MetalPreviewLayer) -> (CVPixelBuffer?, Int) {
        layer.renderLock.lock()
        defer { layer.renderLock.unlock() }
        return (layer.lastBuffer, layer.presentCount)
    }

    private func frame(_ level: UInt8, width: Int = 64,
                       height: Int = 36) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    row[x * 4] = level
                    row[x * 4 + 1] = level
                    row[x * 4 + 2] = level
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// A 2vuy frame — what a YUV capture delivers, and the format the debug
    /// probe has to step over instead of reading as BGRA.
    private func yuvFrame(width: Int = 64, height: Int = 36) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_422YpCbCr8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        return out
    }

    // MARK: - the draw path

    /// A presented frame is adopted, and the drawable size the view asked for is
    /// applied by the RENDERER — assigning it from the layout pass reallocates
    /// the drawable pool under a producer parked in `nextDrawable()`.
    @Test func presentingAFrameAdoptsItAndTheRequestedDrawableSize() throws {
        let layer = MetalPreviewLayer()
        layer.setDrawableSize(CGSize(width: 128, height: 64))
        // nothing to redraw yet, so the size is still only requested
        drain(layer)
        #expect(layer.drawableSize == .zero)

        let source = frame(0x60)
        layer.present(source)
        drain(layer)

        let (adopted, _) = state(of: layer)
        #expect(adopted === source, "the frame was not taken in")
        #expect(layer.drawableSize == CGSize(width: 128, height: 64),
                "the renderer never applied the requested size")
    }

    /// Latest frame wins. A surface that cannot keep up must skip frames, not
    /// queue them: the producer behind it is the capture queue.
    @Test func theNewestFrameWinsWhenTheDrawCannotKeepUp() throws {
        let layer = makeLayer()
        layer.debugTag = "test" // makes the render count observable
        var buffers: [CVPixelBuffer] = []
        for index in 0..<40 {
            let buffer = frame(UInt8(0x10 + index * 4))
            buffers.append(buffer)
            layer.present(buffer)
        }
        drain(layer)

        let (adopted, renders) = state(of: layer)
        #expect(adopted === buffers.last, "an older frame was left on screen")
        #expect(renders > 0, "nothing was rendered at all")
        #expect(renders < buffers.count,
                "all \(buffers.count) frames were drawn — latest-wins is gone")
    }

    /// Signal loss blanks the surface. Freezing the last frame instead is how an
    /// operator ends up watching a still of a shot that stopped ten minutes ago.
    @Test func clearingToBlackLetsGoOfTheLastFrame() throws {
        let layer = makeLayer()
        layer.present(frame(0xC0))
        drain(layer)
        #expect(state(of: layer).0 != nil)

        layer.clearToBlack()
        drain(layer)
        #expect(state(of: layer).0 == nil,
                "the surface still holds the frame it was told to drop")
    }

    /// A resize while paused (or with no signal) has to re-render the frame that
    /// is already there — no new frame is coming to fill the new drawable, and
    /// the old one stretched to the new bounds is the bug this fixed.
    @Test func aResizeWhilePausedRedrawsTheFrameOnScreen() throws {
        let layer = makeLayer(size: CGSize(width: 128, height: 64))
        let source = frame(0x50)
        layer.present(source)
        drain(layer)
        #expect(layer.drawableSize == CGSize(width: 128, height: 64))

        layer.setDrawableSize(CGSize(width: 256, height: 128))
        drain(layer)

        #expect(layer.drawableSize == CGSize(width: 256, height: 128))
        #expect(state(of: layer).0 === source,
                "the re-render lost the frame it was supposed to redraw")

        // the same size again is not a resize and costs nothing
        let before = state(of: layer).1
        layer.setDrawableSize(CGSize(width: 256, height: 128))
        drain(layer)
        #expect(state(of: layer).1 == before)
    }

    /// The parity probe reads raw BGRA bytes. A YUV frame must make it step
    /// over the read rather than index a plane that is not there.
    @Test func theDebugProbeStepsOverANonBGRAFrame() throws {
        let layer = makeLayer()
        layer.debugTag = "yuv"
        let source = try #require(yuvFrame())

        layer.present(source)
        drain(layer)

        let (adopted, renders) = state(of: layer)
        #expect(adopted === source)
        #expect(renders == 1, "the probe did not run over the frame")
    }

    /// Turning the operator's aids on re-renders what is on screen (they are
    /// applied inside the draw, so nothing else would update a paused frame),
    /// and setting the same value again does not.
    @Test func assistChangesRedrawTheFrameOnScreen() throws {
        let layer = makeLayer()
        layer.debugTag = "assist"
        let source = frame(0x70)
        layer.present(source)
        drain(layer)
        let baseline = state(of: layer).1

        var assist = ViewAssist()
        assist.colorTool = .falseColor
        assist.zebraOn = true
        assist.peakingOn = true
        assist.desqueeze = 1.33
        assist.punchIn = 2
        assist.panX = 0.2
        assist.panY = -0.1
        layer.setAssist(assist)
        drain(layer)

        let (adopted, renders) = state(of: layer)
        #expect(adopted === source)
        #expect(renders > baseline, "the aids never reached the screen")
        layer.renderLock.lock()
        let applied = layer.assist
        layer.renderLock.unlock()
        #expect(applied == assist)

        // an unchanged assist must not cost a GPU pass per settings write
        let settled = state(of: layer).1
        layer.setAssist(assist)
        drain(layer)
        #expect(state(of: layer).1 == settled)
    }

    /// A drawable smaller than two pixels is not something to draw into; the
    /// layer must decline instead of asking for one.
    @Test func aDegenerateDrawableSizeIsDeclined() throws {
        let layer = MetalPreviewLayer()
        layer.setDrawableSize(CGSize(width: 1, height: 1))
        layer.debugTag = "tiny"
        layer.present(frame(0x40))
        drain(layer)

        // the frame is still taken in — a later resize re-renders it
        #expect(state(of: layer).0 != nil)
        layer.clearToBlack()
        drain(layer)
        #expect(state(of: layer).0 == nil)
    }
}
