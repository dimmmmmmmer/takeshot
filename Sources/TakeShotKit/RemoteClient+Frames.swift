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
    /// Take every whole frame out of the buffer and answer it.
    ///
    /// The frames already handled are dropped ONCE, at the end, rather than at
    /// every turn of the loop — which, with the decoder no longer copying the
    /// buffer either (`RemoteWebSocketFrame.decode`), is what makes draining
    /// cost the bytes that arrived instead of the square of the frames in them.
    ///
    /// It was the square. Both halves copied whatever was still unread, once
    /// per frame, and how many frames one arrival holds is the client's choice:
    /// the smallest frame there is, a six-byte masked ping, packs 2731 of them
    /// into the 16 KB this connection reads at a time. Measured on the
    /// development Mac in a release harness, best of three, decoding one
    /// arrival of those pings:
    ///
    /// | arrival | frames | before | after |
    /// | --- | --- | --- | --- |
    /// | 16 KB | 2 731 | 3.3 ms | 0.4 ms |
    /// | 128 KB | 21 846 | 168 ms | 3.5 ms |
    ///
    /// The ratio is not the point; the SHAPE is. Before, absorbing input got
    /// slower the more of it arrived at once — 5.0 MB/s at 16 KB falling to
    /// 0.78 MB/s at 128 — so the eight sockets between them needed only about
    /// five megabytes a second to own this server's one serial queue, and every
    /// other phone's timecode, REC press and camera tile is on it. After, the
    /// rate is flat at 37-44 MB/s whatever the arrival, which is more than a set
    /// Wi-Fi network can hand over in the first place.
    ///
    /// (The 16 KB row is the one that matters today: `receive` asks for at most
    /// that much, so a completed frame never waits behind more. The 128 KB row
    /// is what the buffer ceiling allows, and is here because that read size is
    /// a constant somebody could reasonably raise.)
    func drainFrames() {
        var offset = buffer.startIndex
        defer { dropHandled(through: offset) }
        while !closed {
            let decoded: (frame: RemoteWebSocketFrame, consumed: Int)?
            do {
                // `consumed` is a count, not an index: a Data slice keeps the
                // indices of the buffer it came from, and the decoder reads its
                // argument from ITS OWN start, so the offset lives here.
                decoded = try RemoteWebSocketFrame.decode(from: buffer[offset...])
            } catch {
                offset = buffer.endIndex
                close(code: 1002)
                return
            }
            guard let decoded else { return }
            offset += decoded.consumed
            handle(decoded.frame)
        }
    }

    /// Forget the bytes already turned into frames. Nothing here re-enters
    /// `drainFrames`, so one trim on the way out is the whole bookkeeping.
    private func dropHandled(through offset: Data.Index) {
        guard offset > buffer.startIndex else { return }
        buffer = offset < buffer.endIndex ? Data(buffer[offset...]) : Data()
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
