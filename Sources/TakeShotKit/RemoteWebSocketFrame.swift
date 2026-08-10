import Foundation

/// RFC 6455 framing, in the one direction pair this app needs: a browser sends
/// masked text/ping/close frames, the server answers with unmasked ones.
///
/// See `RemoteHTTP` for why the framing is not `NWProtocolWebSocket`'s.
struct RemoteWebSocketFrame: Equatable {
    /// The opcodes that reach the app. Anything else is answered with a close.
    enum Opcode: UInt8, Equatable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        /// RFC 6455 §5.5: the high bit of the opcode marks a control frame,
        /// which is short and never fragmented.
        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    var isFinal: Bool
    var opcode: Opcode
    var payload: Data

    /// A frame refused before it is read: the payload length the client
    /// announced is larger than anything the protocol here can mean.
    ///
    /// The commands are forty bytes. Without a ceiling, a single header
    /// claiming 2^63 bytes has the server buffering until the app is killed —
    /// on a machine that is recording at the time.
    static let maximumPayload = 64 * 1024

    /// Decode one frame from the front of `buffer`.
    ///
    /// Returns the frame and how many bytes it consumed, `nil` while the frame
    /// is still arriving, and throws when the stream cannot be trusted any
    /// more — which the caller answers by closing, never by resynchronizing:
    /// there is no way to find the next frame boundary in a stream you have
    /// lost track of.
    ///
    /// The three "still arriving" points and the four ways a frame is refused
    /// used to be one function, and reading it meant holding all seven exits in
    /// your head at once. It is the same four stages a frame actually has: the
    /// two fixed bytes, the announced length, the rules that length has to
    /// obey, and the masked body — each of which either has enough bytes to
    /// decide or does not.
    ///
    /// **Read through the buffer, never copied out of it.** `drainFrames` calls
    /// this once per frame against one arrival, so a `[UInt8](buffer)` here was
    /// a copy of everything still unread, per frame — quadratic in the number
    /// of frames one arrival carries, and the client chooses that number. See
    /// `RemoteClient.drainFrames` for the measurement; the two halves are the
    /// same fault and only fix it together.
    static func decode(from buffer: Data) throws -> (frame: RemoteWebSocketFrame,
                                                     consumed: Int)? {
        try buffer.withUnsafeBytes { raw in
            try decode(bytes: raw.bindMemory(to: UInt8.self))
        }
    }

    private static func decode(
        bytes: UnsafeBufferPointer<UInt8>
    ) throws -> (frame: RemoteWebSocketFrame, consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let opcode = try opcode(in: bytes)
        guard let (length, afterLength) = try payloadLength(in: bytes) else {
            return nil
        }
        try checkRules(length: length, opcode: opcode, first: bytes[0])
        let consumed = afterLength + 4 + length
        guard bytes.count >= consumed else { return nil }
        return (RemoteWebSocketFrame(
                    isFinal: bytes[0] & 0x80 != 0, opcode: opcode,
                    payload: unmasked(bytes, at: afterLength, length: length)),
                consumed)
    }

    /// Stage 1 — the two fixed bytes: what kind of frame this is, and the two
    /// rules that do not depend on how long it says it is.
    private static func opcode(
        in bytes: UnsafeBufferPointer<UInt8>) throws -> Opcode {
        guard bytes[0] & 0x70 == 0 else { throw RemoteFrameError.reservedBits }
        guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else {
            throw RemoteFrameError.unknownOpcode
        }
        // RFC 6455 §5.1: every frame from a client is masked. An unmasked one
        // is either a broken client or someone speaking a different protocol
        // at the port.
        guard bytes[1] & 0x80 != 0 else { throw RemoteFrameError.notMasked }
        return opcode
    }

    /// Stage 3 — what the announced length is allowed to be, now that both it
    /// and the opcode are known.
    private static func checkRules(length: Int, opcode: Opcode,
                                   first: UInt8) throws {
        guard length <= maximumPayload else { throw RemoteFrameError.tooLarge }
        guard opcode.isControl else { return }
        // A control frame carries at most 125 bytes and is never fragmented.
        guard length <= 125, first & 0x80 != 0 else {
            throw RemoteFrameError.badControlFrame
        }
    }

    /// Stage 4 — the body, XORed back out from under its 4-byte mask.
    private static func unmasked(_ bytes: UnsafeBufferPointer<UInt8>,
                                 at offset: Int, length: Int) -> Data {
        let mask = Array(bytes[offset..<(offset + 4)])
        let start = offset + 4
        var payload = Array(bytes[start..<(start + length)])
        for index in payload.indices {
            payload[index] ^= mask[index % 4]
        }
        return Data(payload)
    }

    /// The announced payload length and the offset just past it, or nil while
    /// the extended length field is still arriving.
    ///
    /// Its own function because the three length forms are where a frame parser
    /// goes wrong, and because reading them inline put `decode` over the
    /// project's complexity ceiling — which is the ceiling doing its job.
    private static func payloadLength(
        in bytes: UnsafeBufferPointer<UInt8>
    ) throws -> (length: Int, offset: Int)? {
        let short = Int(bytes[1] & 0x7F)
        switch short {
        case 126:
            guard bytes.count >= 4 else { return nil }
            return (Int(bytes[2]) << 8 | Int(bytes[3]), 4)
        case 127:
            guard bytes.count >= 10 else { return nil }
            var wide = 0
            for index in 2..<10 {
                // The top bit must be zero per the RFC; `maximumPayload`
                // rejects everything this large anyway, and the guard keeps the
                // shift itself from trapping on a hostile header.
                guard wide <= Int.max >> 8 else {
                    throw RemoteFrameError.tooLarge
                }
                wide = wide << 8 | Int(bytes[index])
            }
            return (wide, 10)
        default:
            return (short, 2)
        }
    }
}

/// Why a frame was refused. Every case ends the connection.
enum RemoteFrameError: Error, Equatable {
    case reservedBits
    case unknownOpcode
    case notMasked
    case tooLarge
    case badControlFrame
}
