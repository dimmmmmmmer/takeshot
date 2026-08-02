import Foundation

/// The camera frames, on the same socket as everything else: one binary
/// message per frame, one frame in flight per client, latest-wins behind it.
///
/// Split out of `RemoteClient` the way the HTTP and framing halves are — the
/// frame stream is its own discipline. Two rules carry the whole thing:
///
/// - **One in flight.** The next frame is handed to the transport only after
///   the previous one's completion lands. `contentProcessed` is
///   Network.framework's backpressure signal, so a phone that reads slowly is
///   paced by its own socket — it gets fewer frames, never a growing queue.
/// - **Latest wins while waiting.** A frame arriving behind an unfinished one
///   replaces the held frame for its camera instead of queueing after it. A
///   stalled phone therefore holds at most one frame in flight plus one per
///   camera — bounded, whatever the wire does.
///
/// Frame bytes are deliberately NOT counted into `inFlightBytes`: that ledger
/// exists to drop a client whose STATUS stream is going nowhere, and its
/// ceiling is sized for 180-byte statuses. One JPEG would trip it on the spot
/// and drop every phone that ever watched a frame. The frame path needs no
/// ledger of its own — the one-in-flight rule already bounds it — and a truly
/// dead socket is still dropped by the status ledger exactly as before.
extension RemoteClient {
    /// The frame message's shape: one camera byte, then the JPEG. Stated once
    /// so the page and the tests read the same offset.
    static let frameHeaderBytes = 1

    /// Send one camera's fresh JPEG, or hold it if one is already in flight.
    /// Silently nothing for a socket that has not asked for frames — the
    /// status path behaves the same way before authentication.
    func send(frame: Data, camera: UInt8) {
        guard upgraded, authenticated, wantsMultiview, !closed else { return }
        guard !frameInFlight else {
            pendingFrames[camera] = frame
            return
        }
        writeFrame(camera: camera, payload: frame)
    }

    private func writeFrame(camera: UInt8, payload: Data) {
        frameInFlight = true
        frameSends += 1
        var message = Data([camera])
        message.append(payload)
        let data = RemoteWebSocketFrame.encode(opcode: .binary,
                                               payload: message)
        // The completion runs on the connection's queue, which is the
        // server's — the same confinement every other member here relies on.
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.frameInFlight = false
            self.sendHeldFrame()
        })
    }

    /// The completion landed; send whatever newest frame accumulated while it
    /// was out. Lowest camera first so neither tile can starve the other.
    private func sendHeldFrame() {
        guard !closed, wantsMultiview,
              let camera = pendingFrames.keys.min(),
              let payload = pendingFrames.removeValue(forKey: camera)
        else { return }
        writeFrame(camera: camera, payload: payload)
    }
}
