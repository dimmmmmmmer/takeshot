import Foundation

/// WebSocket framing, once the connection has been upgraded: taking whole
/// frames out of the buffer, answering the control ones, and reassembling a
/// message that arrived in pieces.
///
/// Split out of `RemoteClient`. Everything here is RFC 6455 bookkeeping, and it
/// answers a protocol error the same way every time — by closing, never by
/// trying to resynchronize: there is no way to find the next frame boundary in
/// a stream you have lost track of.
extension RemoteClient {
    func drainFrames() {
        while !closed {
            let decoded: (frame: RemoteWebSocketFrame, consumed: Int)?
            do {
                decoded = try RemoteWebSocketFrame.decode(from: buffer)
            } catch {
                close(code: 1002)
                return
            }
            guard let decoded else { return }
            // `consumed` is a count, not an index: Data slices keep the
            // indices of the buffer they came from.
            let next = buffer.index(buffer.startIndex, offsetBy: decoded.consumed)
            buffer = Data(buffer[next...])
            handle(decoded.frame)
        }
    }

    private func handle(_ frame: RemoteWebSocketFrame) {
        switch frame.opcode {
        case .close:
            close(code: 1000)
        case .ping:
            write(RemoteWebSocketFrame.encode(opcode: .pong,
                                              payload: frame.payload))
        case .pong:
            break
        case .binary:
            // The protocol here is JSON text in both directions.
            close(code: 1003)
        case .text, .continuation:
            accumulate(frame)
        }
    }

    private func accumulate(_ frame: RemoteWebSocketFrame) {
        // RFC 6455 §5.4: a continuation with no message open, and a new message
        // arriving while one is still open, are both protocol errors. Appending
        // them regardless is worse than refusing them — it builds one "command"
        // out of two unrelated halves, and the halves come from the network.
        guard (frame.opcode == .continuation) == fragmentOpen else {
            resetFragment()
            close(code: 1002)
            return
        }
        fragment.append(frame.payload)
        fragmentOpen = !frame.isFinal
        guard fragment.count <= Self.maximumBuffer else {
            close(code: 1009)
            return
        }
        guard frame.isFinal else { return }
        // RFC 6455 §5.6: a text frame that is not valid UTF-8 is a protocol
        // error (1007), not something to repair into a command.
        guard let text = String(bytes: fragment, encoding: .utf8) else {
            resetFragment()
            close(code: 1007)
            return
        }
        resetFragment()
        handle(text: text)
    }

    private func resetFragment() {
        fragment = Data()
        fragmentOpen = false
    }
}
