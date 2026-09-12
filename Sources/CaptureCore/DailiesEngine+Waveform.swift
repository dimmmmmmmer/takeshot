@preconcurrency import AVFoundation
import Foundation

/// **The sound files timecode cannot place**, and the envelopes that can
/// (owner: "ну и если ВДРУГ есть возможность – синк дублей не только по
/// таймкоду со звуком но еще и по вейвформе").
///
/// `SoundSync` is the right answer when there is timecode: it is exact and it
/// costs nothing to read. A recorder without it writes a file with no `bext`,
/// which `BroadcastWaveFacts` says plainly "cannot be matched to anything" —
/// and those are the files this reads, once per run, so that every take of the
/// day can then be matched against them by ear.
///
/// Deliberately ONLY those. A file whose timecode is present but wrong is a
/// different problem with a different fix — it would have to be noticed first,
/// and a run that quietly overrode a recordist's timecode because a
/// correlation disagreed with it would be the app being confidently wrong
/// about the one thing the file states about itself.
extension DailiesEngine {
    /// The envelopes of every sound file with no timecode, or nothing at all
    /// when the run was not asked to listen.
    static func waveformCandidates(_ sounds: [BroadcastWaveFacts],
                                   enabled: Bool)
        async -> [WaveformSync.Candidate] {
        guard enabled else { return [] }
        var out: [WaveformSync.Candidate] = []
        for sound in sounds where sound.startSecondsSinceMidnight == nil {
            let envelope = await DailiesTranscode.envelope(
                of: AVURLAsset(url: sound.url))
            guard !envelope.isEmpty else { continue }
            out.append(WaveformSync.Candidate(sound: sound,
                                              envelope: envelope))
        }
        return out
    }

    /// The files that belong to this take, decided by ear.
    ///
    /// One envelope of the take, then one alignment per candidate. A match
    /// that does not clear `WaveformSync.Alignment.isCredible` is dropped
    /// silently and the take simply has no sound from that file: attaching a
    /// roll to the wrong take is worse than attaching it to nothing, and there
    /// is nothing an operator could do with a warning about a correlation.
    /// **A URL and not the probe's own asset.** The session is about to open
    /// its reader on that instance, and the two reads have no business
    /// sharing one — a fresh asset on the same file costs nothing and cannot
    /// interact with it at all.
    static func waveformMatches(for url: URL,
                                in candidates: [WaveformSync.Candidate])
        async -> [SoundSync.Match] {
        guard !candidates.isEmpty else { return [] }
        let picture = await DailiesTranscode.envelope(of: AVURLAsset(url: url))
        guard !picture.isEmpty else { return [] }
        return candidates.compactMap { candidate in
            guard let found = WaveformSync.locate(picture: picture,
                                                  sound: candidate.envelope)
            else { return nil }
            return SoundSync.Match(sound: candidate.sound,
                                   offsetIntoSound: found.offsetIntoSound)
        }
    }
}
