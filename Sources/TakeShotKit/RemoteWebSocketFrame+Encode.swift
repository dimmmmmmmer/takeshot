import Foundation

/// The other direction: what the server sends.
///
/// Split out of `RemoteWebSocketFrame`, which decodes what the browser sends.
/// The two halves have opposite rules — a client frame is always masked and may
/// be fragmented, a server frame is never masked and is always one frame per
/// message — and keeping them apart is what stops one set of rules from being
/// applied to the other.
extension RemoteWebSocketFrame {
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
