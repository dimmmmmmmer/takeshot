import Foundation
import Network
import os

/// The embedded server the phones on the set network talk to: one page, one
/// socket, one port.
///
/// Everything mutable lives on `queue`, a serial queue of its own — the capture
/// queue owns per-frame work and must never wait on a socket, and the MainActor
/// must never wait on one either. The two values that cross in from outside
/// (the PIN and the rendered page) sit behind a lock rather than being closure
/// properties: a closure read on one thread while another writes it hands the
/// caller a function pointer paired with the wrong context (see
/// docs/ARCHITECTURE.md).
final class RemoteServer: @unchecked Sendable {
    /// What the server reports back. Handed in at construction and never
    /// replaced, for the same reason.
    struct Handlers: Sendable {
        /// A command that passed the PIN check, on the server's queue.
        var command: @Sendable (RemoteCommand) -> Void
        /// The listener is up on this port (the bound one — the caller may
        /// have asked for 0).
        var ready: @Sendable (UInt16) -> Void
        /// The listener died. A port already in use arrives here.
        var failed: @Sendable (String) -> Void
    }

    /// The values the app pushes in while the server runs: the PIN and the
    /// localized page. Both change without a restart (the operator switches
    /// language, or regenerates the code).
    private struct Shared {
        var pin: String
        var page: Data
    }

    /// A handful of phones is the whole use case. The cap is what stops a
    /// script pointed at the port from opening sockets until the app that is
    /// recording runs out of file descriptors.
    static let maximumClients = 8

    /// Binds retried when the port is reported already taken, before the failure
    /// is surfaced to the operator.
    ///
    /// A rebind on the same port races the previous listener's cancel, which is
    /// asynchronous: `stop()` returns long before the socket is released. The
    /// operator meets that race by editing the port field or by switching the
    /// remote off and straight back on, and without a retry the answer is
    /// "Address already in use" and a switch that turned itself off — blamed on
    /// whatever else is on the machine. A port another process really owns is
    /// still reported, one short retry window later.
    static let bindRetries = 4
    static let bindRetryDelay = DispatchTimeInterval.milliseconds(120)

    static let log = Logger(subsystem: "com.takeshot.app", category: "remote")

    private let handlers: Handlers
    private let queue = DispatchQueue(label: "com.takeshot.remote")
    private let shared: OSAllocatedUnfairLock<Shared>

    // MARK: - queue-confined state

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: RemoteClient] = [:]
    /// The port `start` was asked for, kept for a retried bind.
    private var requestedPort: UInt16 = 0
    private var bindAttempts = 0
    /// `stop()` has been called. A retry scheduled before it must not bring a
    /// listener back up behind the operator's switch.
    private var isStopped = false
    /// The last status pushed, replayed to a client the moment it authenticates
    /// so a phone picked up mid-take shows the take rather than a blank readout.
    private var lastStatus: String?

    init(pin: String, page: Data, handlers: Handlers) {
        self.handlers = handlers
        self.shared = OSAllocatedUnfairLock(
            initialState: Shared(pin: pin, page: page))
    }

    /// Start listening. `port` 0 binds an ephemeral one and reports it through
    /// `handlers.ready` — which is how the tests avoid claiming a fixed port on
    /// the machine running them.
    func start(port: UInt16) {
        queue.async { [self] in
            guard listener == nil, !isStopped else { return }
            requestedPort = port
            bindAttempts = 0
            bind()
        }
    }

    /// Stop listening and drop every client. Safe to call when not running, and
    /// final: a stopped server does not start again, because a retried bind may
    /// still be in flight behind it. The controller builds a fresh one to come
    /// back up, which is also what makes the PIN and the page it was handed
    /// current rather than whatever they were when it went down.
    func stop() {
        queue.async { [self] in
            isStopped = true
            dropListener()
            for client in clients.values { client.close(code: 1001) }
            clients.removeAll()
            lastStatus = nil
        }
    }

    /// How many connections the server is holding a slot for.
    ///
    /// The cap on those slots is what stops a script pointed at the port from
    /// using up the app's file descriptors, so whether they come back is worth
    /// being able to ask directly rather than inferring from a connection that
    /// did or did not get through.
    var clientCount: Int {
        // Safe from any thread: nothing on this queue ever waits on another one.
        queue.sync { clients.count }
    }

    /// Push a status to every authenticated client.
    func broadcast(_ status: RemoteStatus) {
        let json = status.json
        queue.async { [self] in
            lastStatus = json
            for client in clients.values { client.send(text: json) }
        }
    }

    /// Replace the served page — the operator changed the UI language, and the
    /// labels on the phone follow the app.
    func setPage(_ page: Data) {
        shared.withLock { $0.page = page }
    }

    /// Replace the PIN. Sockets already authenticated stay open; their next
    /// command carries the old code and is refused, which is what a rotated
    /// code has to mean.
    func setPIN(_ pin: String) {
        shared.withLock { $0.pin = pin }
    }

    // MARK: - internals (queue only)

    private func bind() {
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

    private func dropListener() {
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

    // MARK: - called by RemoteClient, on the same queue

    var currentPIN: String { shared.withLock { $0.pin } }
    var currentPage: Data { shared.withLock { $0.page } }
    var currentStatus: String? { lastStatus }

    func dispatch(_ command: RemoteCommand) {
        handlers.command(command)
    }

    func clientClosed(_ client: RemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
    }
}
