@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// **Feeding the daily's sound tracks**, which is a different job from the
/// picture's and a more delicate one.
///
/// Split out of the transcode when that type reached its length ceiling, and a
/// coherent cut: everything here is about the legs — where each one's clock
/// starts, how far ahead of the picture it is kept, and when it is closed.
/// Every rule in it exists because of the same trap from a different angle —
/// `AVAssetWriter` holds an input back while another lags, so a leg that runs
/// dry silently, or one that runs far past the picture, stalls the whole run.
extension DailiesTranscode {

    /// **Where each leg's clock lands on the daily's**, known only now.
    ///
    /// The writer's session starts at the first picture frame's own timestamp,
    /// so that is what a sound sample has to be measured against. A sample at
    /// `t` seconds into a sound FILE is the picture at `t - offsetIntoSound`
    /// seconds in, so it belongs at `firstPTS + (t - offsetIntoSound)` — one
    /// constant per leg.
    ///
    /// The camera's leg gets zero: its samples come off the same asset as the
    /// picture and are already on that clock. Shifting them would move the
    /// take's own sound by the length of its own head.
    func startAudio(session: DailiesSession, at firstPTS: CMTime) {
        pendingAudio = Array(repeating: nil, count: session.audio.count)
        audioShift = session.audio.map { leg in
            guard leg.reader != nil else { return .zero }
            return firstPTS - CMTime(seconds: leg.offsetIntoSound,
                                     preferredTimescale: 48_000)
        }
    }

    /// Every audio leg, pumped up to the picture's current time.
    ///
    /// One loop per leg rather than one shared loop, because the legs are
    /// different assets with different clocks: the camera's samples are
    /// already on the daily's timeline and a sound file's are on the
    /// recordist's, shifted onto it by `audioShift`.
    func pumpAudio(upTo limit: CMTime,
                   session: DailiesSession) async throws {
        for (index, leg) in session.audio.enumerated() {
            try await pump(leg: leg, at: index, upTo: limit, session: session)
        }
    }

    private func pump(leg: DailiesSession.AudioLeg, at index: Int,
                      upTo limit: CMTime,
                      session: DailiesSession) async throws {
        guard index < pendingAudio.count else { return }
        let shift = index < audioShift.count ? audioShift[index] : .zero
        while true {
            if pendingAudio[index] == nil {
                pendingAudio[index] = leg.output.copyNextSampleBuffer()
            }
            guard let sample = pendingAudio[index] else {
                // **An exhausted leg is finished HERE, not at the end.** A
                // writer waits for every input it was given, so a leg that has
                // run out and says nothing holds the picture back for the rest
                // of the take — the multi-input stall, from the other side.
                // Marking it the moment it runs dry lets the rest of the run
                // proceed; `finish` marks whatever is left.
                if !finishedAudio.contains(index) {
                    finishedAudio.insert(index)
                    leg.input.markAsFinished()
                }
                return
            }
            let shifted = Self.shifted(sample, by: shift) ?? sample
            // Every leg by the SAME factor: the balance between the camera's
            // sound and the recordist's is theirs, not this app's.
            let stamped = AudioGain.apply(audioFactor, to: shifted) ?? shifted
            guard CMSampleBufferGetPresentationTimeStamp(stamped) <= limit
            else { return }
            while !leg.input.isReadyForMoreMediaData {
                try checkCancelled() // see `append` above
                guard session.writer.status == .writing else {
                    throw DailiesAbort.failed(
                        DailiesSession.failure(of: session.writer))
                }
                try await Task.sleep(for: .milliseconds(2)) // see `append`
            }
            leg.input.append(stamped)
            pendingAudio[index] = nil
        }
    }
}
