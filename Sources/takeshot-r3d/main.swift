import CR3D
import Foundation

// CLI smoke test for the R3D bridge: open a clip, print what the app would read
// off it, and time the decode at every scale.
//
// This exists because the test suite cannot cover the decode path at all. A
// .braw or a .dng can be stood up synthetically; an .r3d cannot — there is no
// encoder, and RED's SDK ships no sample clip. So the numbers in the README come
// from pointing this at real footage, and everything that CAN be tested without
// footage (the scale rule, the metadata plumbing, the failure messages, the
// colour state) is tested in TakeShotKitTests instead.
//
// Point it at RED's redistributables if they are not beside the binary:
//   TAKESHOT_R3D_LIBS=vendor/R3DSDK/Redistributable/mac \
//     swift run -c release takeshot-r3d /path/to/A001_C001_0101XX_001.R3D

let scales: [(name: String, scale: CR3DDecodeScale)] = [
    ("full", .full), ("1/2", .half), ("1/4", .quarter), ("1/8", .eighth),
]

func report(_ line: String) {
    print(line)
}

func describe(_ clip: CR3DClip) {
    report("resolution          : \(clip.width) x \(clip.height)")
    report("frame rate          : \(clip.frameRate) fps")
    report("timecode rate       : \(clip.timecodeFrameRate) fps")
    report("frames              : \(clip.frameCount)")
    report("start TC (absolute) : \(clip.startTimecode ?? "—")")
    report("start TC (edge)     : \(clip.startEdgeTimecode ?? "—")")
    report("camera              : \(clip.cameraModel ?? "—")")
    report("sensor              : \(clip.sensorName ?? "—")")
    report("reel / clip         : \(clip.reelID ?? "—") / \(clip.clipID ?? "—")")
    report("original filename   : \(clip.originalFilename ?? "—")")
    report("REDCODE             : \(clip.redcodeFormat ?? "—")")
    report("lens                : \(clip.lensName ?? "—")")
    report("ISO / Kelvin / tint : \(clip.iso) / \(clip.kelvin) / \(clip.tint)")
    report("colour pipeline     : \(clip.colorPipelineName)")
    report("output transform    : \(clip.outputTransformName)")
    report("camera 3D LUT       : \(clip.cameraLUTName ?? "none")"
        + (clip.cameraLUTApplied ? " (applied)" : " (not applied)"))
}

/// Decode a run of frames and report the rate. Sequential from frame 0, which is
/// what playback does; a random-access pattern would measure the volume instead.
func measure(path: String, scale: CR3DDecodeScale, name: String) {
    let clip: CR3DClip
    do {
        clip = try CR3DClip(path: path, scale: scale, applyCameraLUT: false)
    } catch {
        report("\(name): \(error.localizedDescription)")
        return
    }
    let frames = min(Int(clip.frameCount), 120)
    guard frames > 0 else { return }
    var decoded = 0
    let start = Date()
    for index in 0..<frames {
        guard let buffer = clip.copyFrame(at: UInt64(index)) else {
            report("\(name): stopped at frame \(index) — "
                + (clip.lastDecodeError ?? "unknown"))
            break
        }
        decoded += 1
        _ = buffer // released by ARC; the pool recycles it
    }
    let elapsed = Date().timeIntervalSince(start)
    guard decoded > 0, elapsed > 0 else { return }
    let raster = "\(clip.decodedWidth)x\(clip.decodedHeight)"
    let rate = String(format: "%6.2f", Double(decoded) / elapsed)
    report("\(name.padding(toLength: 5, withPad: " ", startingAt: 0))"
        + "\(raster.padding(toLength: 12, withPad: " ", startingAt: 0))"
        + "\(rate) fps  (\(decoded) frames in "
        + String(format: "%.2f", elapsed) + "s)")
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    report("usage: takeshot-r3d <clip.R3D>")
    report("")
    report("R3D SDK: \(CR3DClip.sdkVersion() ?? "not built in")")
    report("available: \(CR3DClip.isSDKAvailable())"
        + (CR3DClip.unavailableReason().map { " — \($0)" } ?? ""))
    exit(2)
}

report("R3D SDK: \(CR3DClip.sdkVersion() ?? "not built in")")
guard CR3DClip.isSDKAvailable() else {
    report("unavailable: \(CR3DClip.unavailableReason() ?? "unknown")")
    exit(1)
}

do {
    let clip = try CR3DClip(path: arguments[1], scale: .auto,
                            applyCameraLUT: false)
    describe(clip)
    report("auto scale          : 1/\(clip.scaleDivisor) "
        + "(\(clip.decodedWidth) x \(clip.decodedHeight))")
} catch {
    report("open failed: \(error.localizedDescription)")
    exit(1)
}

report("")
report("decode rate, sequential from frame 0:")
for entry in scales {
    measure(path: arguments[1], scale: entry.scale, name: entry.name)
}
