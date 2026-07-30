import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Compare tooling: the pinned reference, punch-in, and the wipe/blend push.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Live vs. playback compare mode.
    enum CompareMode: String, CaseIterable, Identifiable {
        case off        // playback only
        case wipe       // wipe
        case blend      // overlay with transparency
        case sideBySide // side by side
        var id: String { rawValue }
    }

    /// Compare wipe direction.
    enum WipeOrientation: String, CaseIterable {
        case vertical    // vertical line, drags horizontally
        case horizontal  // horizontal line, drags vertically
        case diagonal    // 45°
    }

    /// Hotkey punch-in: straight to 2x and back off. Reads the level the pinch
    /// gesture may have left on screen (see +Assist), so the key never toggles
    /// off a magnification it cannot see.
    func togglePunchIn() {
        let magnified = liveAssist.punchIn > 1
        setAssist {
            $0.setPunchIn(magnified ? 1 : 2)
            if magnified {
                $0.panX = 0
                $0.panY = 0
            }
        }
    }
    /// Pin the current frame (live preview or the paused player frame).
    func pinReferenceFromCurrentFrame() {
        if viewerMode == .playback {
            guard let buffer = playbackTap.currentBuffer() else {
                lastError = L("reference_pin_failed")
                return
            }
            pipeline.setPreviewReference(buffer: buffer)
        } else {
            pipeline.pinReferenceFromCurrentFrame()
        }
        referencePinned = true
        // pinning means "compare me": default to the wipe in rec mode
        if compareMode == .off { compareMode = .wipe }
        if viewerMode == .playback { viewerMode = .record }
        pushCompare()
        lastNotice = L("reference_pinned")
    }
    /// Pin a still/photo from the record folder.
    func pinReference(imageURL: URL) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            lastError = L("reference_pin_failed")
            return
        }
        // raw code values, like every other surface in the app
        let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        guard let buffer else {
            lastError = L("reference_pin_failed")
            return
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let task = try? context.startTask(toRender: image, to: destination),
              (try? task.waitUntilCompleted()) != nil else {
            lastError = L("reference_pin_failed")
            return
        }
        pipeline.setPreviewReference(buffer: buffer)
        referencePinned = true
        if compareMode == .off { compareMode = .wipe }
        viewerMode = .record
        pushCompare()
        lastNotice = L("reference_pinned")
    }
    func unpinReference() {
        pipeline.setPreviewReference(buffer: nil)
        referencePinned = false
        pushCompare()
    }
    private static func compareAxis(
        _ orientation: WipeOrientation) -> CompareCompositor.Axis {
        switch orientation {
        case .vertical: return .vertical
        case .horizontal: return .horizontal
        case .diagonal: return .diagonal
        }
    }
    /// Wipe/blend are composited inside the playback render (SwiftUI masking of
    /// video layers drops the colorspace) — push the parameters to the tap,
    /// and to the pipeline when a reference is pinned for live compare.
    func pushCompare() {
        switch compareMode {
        case .off, .sideBySide:
            playbackTap.setCompare(.off)
        case .blend:
            playbackTap.setCompare(.blend(opacity: blendOpacity))
        case .wipe:
            playbackTap.setCompare(.wipe(
                axis: Self.compareAxis(wipeOrientation), position: wipePosition))
        }
        guard referencePinned else {
            pipeline.setPreviewCompare(.off)
            return
        }
        switch compareMode {
        case .off, .sideBySide:
            pipeline.setPreviewCompare(.off)
        case .blend:
            pipeline.setPreviewCompare(.blend(opacity: blendOpacity))
        case .wipe:
            pipeline.setPreviewCompare(.wipe(
                axis: Self.compareAxis(wipeOrientation), position: wipePosition))
        }
    }
}
