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

    /// What the A pane of the A/B split shows.
    enum ComparePaneSource: Equatable {
        case live
        case clip
    }

    /// Which picture belongs in the A pane. One property, read by the pane and
    /// asserted by the tests, because the wipe/blend composite and the split
    /// have to agree on what "the compare source" means — they disagreed, and
    /// A/B against another clip showed live on the left.
    var comparePaneSource: ComparePaneSource {
        compareClipURL == nil ? .live : .clip
    }

    /// Whether the viewer is showing the A|B split rather than one picture.
    ///
    /// Every surface that draws the player reads THIS — the main viewer, the
    /// fullscreen player and the external display. It is one property because
    /// the condition was written out once, in `PreviewView`, and the other two
    /// windows simply did not have it: with A/B engaged they drew the B side
    /// alone, so the operator's window showed two pictures and the director's
    /// monitor showed one. Wipe and blend are absent on purpose — those are
    /// composited into a single frame inside the tap (see `pushCompare`), and a
    /// split of an already-composited picture would show the compare clip twice.
    var showsCompareSplit: Bool {
        viewerMode == .playback && compareMode == .sideBySide
            && playbackURL != nil
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
