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
    static func decode(from buffer: Data) throws -> (frame: RemoteWebSocketFrame,
                                                     consumed: Int)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x70 == 0 else { throw RemoteFrameError.reservedBits }
        guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else {
            throw RemoteFrameError.unknownOpcode
        }
        // RFC 6455 §5.1: every frame from a client is masked. An unmasked one
        // is either a broken client or someone speaking a different protocol
        // at the port.
        guard bytes[1] & 0x80 != 0 else { throw RemoteFrameError.notMasked }

        guard let measured = try payloadLength(in: bytes) else { return nil }
        let (length, offsetAfterLength) = measured
        var offset = offsetAfterLength
        guard length <= maximumPayload else { throw RemoteFrameError.tooLarge }
        // A control frame carries at most 125 bytes and is never fragmented.
        let isControl = opcode.rawValue & 0x8 != 0
        if isControl, length > 125 || bytes[0] & 0x80 == 0 {
            throw RemoteFrameError.badControlFrame
        }

        guard bytes.count >= offset + 4 + length else { return nil }
        let mask = Array(bytes[offset..<(offset + 4)])
        offset += 4
        var payload = Array(bytes[offset..<(offset + length)])
        for index in 0..<payload.count {
            payload[index] ^= mask[index % 4]
        }
        return (RemoteWebSocketFrame(isFinal: bytes[0] & 0x80 != 0,
                                     opcode: opcode,
                                     payload: Data(payload)),
                offset + length)
    }

    /// The announced payload length and the offset just past it, or nil while
    /// the extended length field is still arriving.
    ///
    /// Its own function because the three length forms are where a frame parser
    /// goes wrong, and because reading them inline put `decode` over the
    /// project's complexity ceiling — which is the ceiling doing its job.
    private static func payloadLength(
        in bytes: [UInt8]) throws -> (length: Int, offset: Int)? {
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

    /// A server frame: final, unmasked, one frame per message.
    static func encode(opcode: Opcode, payload: Data) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(count >> 8))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((count >> shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func text(_ message: String) -> Data {
        encode(opcode: .text, payload: Data(message.utf8))
    }

    /// A close frame carrying a status code (1000 normal, 1008 policy).
    static func close(code: UInt16) -> Data {
        encode(opcode: .close,
               payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
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
