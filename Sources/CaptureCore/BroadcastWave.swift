import Foundation

/// **What a sound recordist's file says about itself** — enough of a Broadcast
/// Wave to line it up with a take, and nothing more.
///
/// The owner's ask is timecode-matched sound in the dailies ("если у звука и
/// тейков одинаковые таймкоды, чтоб он автоматически подружил нужные тейки"),
/// and the only thing that can answer "when was this recorded" for a WAV is the
/// `bext` chunk EBU Tech 3285 defines. AVFoundation will happily open a WAV and
/// tell you its duration; it will not tell you the one number this feature
/// turns on.
public struct BroadcastWaveFacts: Sendable, Equatable {
    public var url: URL
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int
    /// `bext` TimeReference divided by the sample rate: seconds since midnight,
    /// exactly, with no frame rate involved anywhere.
    ///
    /// nil — the file carries no `bext`, which is most consumer recorders and
    /// some professional ones. Such a file cannot be matched to anything, and
    /// saying so is the point of the optional: a zero here would silently line
    /// every one of them up with midnight.
    public var startSecondsSinceMidnight: Double?
    /// iXML `CHANNEL_INDEX` (1-based) → `NAME`. Empty when the file carries no
    /// iXML at all — then a channel's name is its number, which is what the
    /// consumer of this has to fall back to.
    public var trackNames: [Int: String]
    public var scene: String?
    public var take: String?

    public var duration: Double { Double(frameCount) / max(1, sampleRate) }

    public init(url: URL, sampleRate: Double, channelCount: Int,
                frameCount: Int, startSecondsSinceMidnight: Double?,
                trackNames: [Int: String] = [:], scene: String? = nil,
                take: String? = nil) {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.startSecondsSinceMidnight = startSecondsSinceMidnight
        self.trackNames = trackNames
        self.scene = scene
        self.take = take
    }
}

/// The RIFF walk itself.
///
/// **Headers only.** A day's sound folder is tens of gigabytes and the sheet
/// scans it while an operator waits, so the `data` chunk is measured from its
/// declared size and seeked past — never read.
public enum BroadcastWaveReader {
    public enum Failure: LocalizedError, Equatable {
        case notAWave(URL)
        case noFormat(URL)

        public var errorDescription: String? {
            switch self {
            case .notAWave(let url):
                return "not a WAVE file: \(url.lastPathComponent)"
            case .noFormat(let url):
                return "no fmt chunk: \(url.lastPathComponent)"
            }
        }
    }

    /// How much iXML is worth reading. A track list is a few kilobytes; a
    /// megabyte of it is a file doing something this reader has no business
    /// trying to understand, and reading it would be the scan's whole budget.
    static let iXMLLimit = 256 * 1024

    /// What the walk collects, so the walk itself stays a walk.
    ///
    /// One struct rather than nine locals: the chunk handlers were inline and
    /// the function came out at complexity 17, which is a reader nobody can
    /// check against the spec line by line.
    struct Parse {
        var sampleRate: Double?
        var channels: Int?
        /// 24 only as the last resort — every professional recorder writes the
        /// field, and a duration computed against 24 bits over a 16-bit file
        /// is half the length. A match window IS a length.
        var bitsPerSample = 24
        var dataBytes: Int?
        /// RF64 states the real length here; the RIFF fields are then
        /// 0xFFFFFFFF and mean nothing. A multitrack day's poly file crosses
        /// 4 GB, so this is not an exotic case.
        var dataBytes64: UInt64?
        var startSamples: Double?
        var names: [Int: String] = [:]
        var scene: String?
        var take: String?
    }

    public static func read(_ url: URL) throws -> BroadcastWaveFacts {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              let riff = String(data: header[0..<4], encoding: .ascii),
              riff == "RIFF" || riff == "RF64",
              String(data: header[8..<12], encoding: .ascii) == "WAVE"
        else { throw Failure.notAWave(url) }

        // Measured ONCE: `seekToEnd` moves the handle, so asking it inside the
        // walk would be a seek per chunk and a bug waiting to be written.
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 12)
        var parse = Parse()

        while true {
            guard let chunkHeader = try handle.read(upToCount: 8),
                  chunkHeader.count == 8,
                  let id = String(data: chunkHeader[0..<4], encoding: .ascii)
            else { break }
            let size = Int(UInt32(littleEndian: chunkHeader[4..<8].uint32))
            let payloadStart = try handle.offset()
            try absorb(id, size: size, from: handle, into: &parse)
            // **Chunks are padded to an even boundary**, and the pad byte is
            // not in the declared size. A file whose odd chunk is not rounded
            // up walks one byte out of step from there on, never finds `bext`,
            // and becomes silently unmatchable.
            let next = payloadStart + UInt64(size + (size % 2))
            guard next < fileSize else { break }
            try handle.seek(toOffset: next)
        }

        guard let sampleRate = parse.sampleRate, let channels = parse.channels,
              sampleRate > 0, channels > 0 else {
            throw Failure.noFormat(url)
        }
        let bytes = parse.dataBytes64.map { Int($0) } ?? parse.dataBytes ?? 0
        let frameCount = bytes / max(1, channels * (parse.bitsPerSample / 8))
        return BroadcastWaveFacts(
            url: url, sampleRate: sampleRate, channelCount: channels,
            frameCount: frameCount,
            startSecondsSinceMidnight: parse.startSamples.map { $0 / sampleRate },
            trackNames: parse.names, scene: parse.scene, take: parse.take)
    }

    /// One chunk, read into the parse. The handle is left anywhere at all —
    /// the walk seeks to the next chunk from the payload's own start.
    private static func absorb(_ id: String, size: Int, from handle: FileHandle,
                               into parse: inout Parse) throws {
        switch id {
        case "ds64":
            if let payload = try handle.read(upToCount: min(size, 28)),
               payload.count >= 28 {
                parse.dataBytes64 = payload[16..<24].uint64
            }
        case "fmt ":
            absorbFormat(try handle.read(upToCount: min(size, 16)), into: &parse)
        case "bext":
            // TimeReference is a 64-bit sample count since midnight, written
            // as TWO 32-bit words at payload offsets 338 and 342 — after
            // Description[256], Originator[32], OriginatorReference[32],
            // OriginationDate[10] and OriginationTime[8]. Reading only the low
            // word is correct to about 24.8 hours at 48 kHz and WRONG from
            // 12.4 hours at 96 kHz, which is a rate features shoot at: the low
            // word wraps mid-night-shoot and the sound lands a day from its
            // picture.
            if let payload = try handle.read(upToCount: min(size, 346)),
               payload.count >= 346 {
                let low = UInt64(payload[338..<342].uint32)
                let high = UInt64(payload[342..<346].uint32)
                parse.startSamples = Double((high << 32) | low)
            }
        case "iXML":
            guard size > 0, size <= iXMLLimit else { break }
            absorbIXML(try handle.read(upToCount: size), into: &parse)
        case "data":
            // Its SIZE only. A day's sound folder is tens of gigabytes and the
            // sheet scans it while an operator waits.
            parse.dataBytes = size
        default:
            break
        }
    }

    /// Channels, rate and the sample width, out of `fmt `.
    private static func absorbFormat(_ payload: Data?, into parse: inout Parse) {
        guard let payload, payload.count >= 8 else { return }
        parse.channels = Int(payload[2..<4].uint16)
        parse.sampleRate = Double(payload[4..<8].uint32)
        guard payload.count >= 16 else { return }
        let bits = Int(payload[14..<16].uint16)
        if bits > 0 { parse.bitsPerSample = bits }
    }

    /// The four flat elements this app reads out of an iXML document.
    private static func absorbIXML(_ payload: Data?, into parse: inout Parse) {
        guard let payload,
              let text = String(data: payload, encoding: .utf8) else { return }
        parse.names = iXMLTrackNames(text)
        parse.scene = iXMLValue("SCENE", in: text)
        parse.take = iXMLValue("TAKE", in: text)
    }

    /// `<TRACK><CHANNEL_INDEX>1</CHANNEL_INDEX><NAME>Boom</NAME></TRACK>` …
    ///
    /// Keyed by the INDEX the file states, never by document order: a recorder
    /// is free to write its tracks in any order, and a boom that comes out as
    /// channel 3 because it was listed third is a mislabelled daily.
    static func iXMLTrackNames(_ text: String) -> [Int: String] {
        var names: [Int: String] = [:]
        for block in text.components(separatedBy: "<TRACK>").dropFirst() {
            let track = block.components(separatedBy: "</TRACK>").first ?? block
            guard let indexText = iXMLValue("CHANNEL_INDEX", in: track),
                  let index = Int(indexText.trimmingCharacters(
                    in: .whitespacesAndNewlines)),
                  let name = iXMLValue("NAME", in: track) else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names[index] = trimmed }
        }
        return names
    }

    /// The first `<TAG>…</TAG>` in a fragment. Deliberately not an XML parser:
    /// what this needs is four flat elements out of a document whose schema
    /// varies by manufacturer, and a strict parse would refuse the whole file
    /// over a namespace nobody reads.
    static func iXMLValue(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>",
                                     range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

private extension Data {
    var uint16: UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    var uint32: UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    var uint64: UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
}
