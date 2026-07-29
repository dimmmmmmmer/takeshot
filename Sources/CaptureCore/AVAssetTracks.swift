import AVFoundation
import CoreMedia

public extension AVAsset {
    /// Tracks of one media type.
    ///
    /// This exists instead of `loadTracks(withMediaType:)` because that call
    /// bridges an Objective-C completion handler, and on macOS 15 with Swift
    /// 6.1 the generated bridge faults in `swift_retain` while resuming its
    /// continuation:
    ///
    ///     #0 swift_retain
    ///     #1 _resumeCheckedThrowingContinuation<A>
    ///     #2 @objc completion handler block … result type [AVAssetTrack]
    ///     #3 __AVLoadValuesAsynchronously_block_invoke
    ///
    /// It is reliable on the CI runner and invisible on a developer machine
    /// two OS versions newer — exactly the kind of difference a user's laptop
    /// will also have. The app reads tracks whenever a clip is opened and on
    /// every folder scan, so shipping a build made on that toolchain would
    /// crash in the field.
    ///
    /// `load(.tracks)` goes through the async-property path — the same one
    /// `load(.duration)` already uses without trouble — and each track is
    /// matched on its format description rather than a deprecated synchronous
    /// property.
    func tracks(ofType mediaType: AVMediaType) async throws -> [AVAssetTrack] {
        guard let wanted = CMMediaType(mediaType) else { return [] }
        var matching: [AVAssetTrack] = []
        for track in try await load(.tracks) {
            let descriptions = try await track.load(.formatDescriptions)
            if descriptions.contains(where: {
                CMFormatDescriptionGetMediaType($0) == wanted
            }) {
                matching.append(track)
            }
        }
        return matching
    }
}

private extension CMMediaType {
    /// `AVMediaType` is a string; format descriptions carry a four-char code.
    init?(_ mediaType: AVMediaType) {
        switch mediaType {
        case .video: self = kCMMediaType_Video
        case .audio: self = kCMMediaType_Audio
        case .timecode: self = kCMMediaType_TimeCode
        case .text: self = kCMMediaType_Text
        case .subtitle: self = kCMMediaType_Subtitle
        case .closedCaption: self = kCMMediaType_ClosedCaption
        case .metadata: self = kCMMediaType_Metadata
        case .muxed: self = kCMMediaType_Muxed
        default: return nil
        }
    }
}
