import Foundation
import Network

/// Getting the listener up, keeping it up, and taking a connection off it.
///
/// Split out of `RemoteServer`: what the app pushes into the server is one job,
/// and binding a port on a machine that may already have something on it is
/// another. All of it runs on the server's own queue.
extension RemoteServer {

    func bind() {
        do {
            let listener = try NWListener(using: Self.parameters(),
                                          on: Self.endpointPort(requestedPort))
            listener.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            handlers.failed(error.localizedDescription)
        }
    }

    func dropListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    /// The port was taken a moment ago. Drop this listener and try once more —
    /// see `bindRetries` for whose port it usually is.
    private func retryBind() {
        bindAttempts += 1
        dropListener()
        queue.asyncAfter(deadline: .now() + Self.bindRetryDelay) { [weak self] in
            guard let self, !self.isStopped, self.listener == nil else { return }
            self.bind()
        }
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // A REC press is 40 bytes and must not sit in a Nagle buffer waiting
        // for company.
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Restarting the server after a port change must not fail for two
        // minutes of TIME_WAIT on the sockets the phones just closed.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func endpointPort(_ port: UInt16) -> NWEndpoint.Port {
        port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            bindAttempts = 0
            let bound = listener?.port?.rawValue ?? 0
            Self.log.info("remote listening on port \(bound, privacy: .public)")
            handlers.ready(bound)
        case .failed(let error), .waiting(let error):
            // `waiting` is where "address already in use" surfaces: the
            // listener does not fail, it parks and retries forever, so an
            // operator who never sees it just believes the remote is broken.
            //
            // Detached before reporting, not in `stop()`: that hops back onto
            // this queue, and a listener that retries in the meantime would
            // report the same failure again — one toast per retry, forever.
            listener?.stateUpdateHandler = nil
            if case .posix(.EADDRINUSE) = error, bindAttempts < Self.bindRetries {
                retryBind()
                return
            }
            handlers.failed(error.localizedDescription)
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maximumClients else {
            connection.cancel()
            return
        }
        let client = RemoteClient(connection: connection, server: self)
        clients[ObjectIdentifier(client)] = client
        client.start(on: queue)
    }
}
