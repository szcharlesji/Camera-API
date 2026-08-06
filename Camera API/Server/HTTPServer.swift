import Foundation
import Network
import os

/// How the server decides which clients may talk to it.
enum AccessMode: String, Codable, CaseIterable, Sendable {
    /// Only connections originating on the device itself. `usbmuxd` proxies host
    /// traffic through the device's loopback interface, so USB clients still work
    /// while anyone on the same Wi-Fi network does not.
    case usbOnly = "usb_only"
    /// Any interface. Intended for development over Wi-Fi; pair it with an auth token.
    case network = "network"
}

struct ServerConfiguration: Sendable {
    var port: UInt16 = 8080
    var accessMode: AccessMode = .usbOnly
    /// When set, every request must carry `Authorization: Bearer <token>`.
    var authToken: String?
}

/// Accepts TCP connections and hands each one to an `HTTPConnection`.
final class HTTPServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private let router: Router
    private let log = Logger(subsystem: "cameraapi", category: "http")
    private let queue = DispatchQueue(label: "cameraapi.server")
    private let lock = NSLock()

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionsByID: [ObjectIdentifier: HTTPConnection] = [:]
    private var _state: State = .idle
    private var _configuration = ServerConfiguration()

    /// Fired on every state transition so the UI can reflect it.
    var onStateChange: (@Sendable (State) -> Void)?

    private(set) var state: State {
        get { lock.withLock { _state } }
        set {
            lock.withLock { _state = newValue }
            onStateChange?(newValue)
        }
    }

    var configuration: ServerConfiguration {
        lock.withLock { _configuration }
    }

    var activeConnectionCount: Int {
        lock.withLock { connectionsByID.count }
    }

    init(router: Router) {
        self.router = router
        router.attach(server: self)
    }

    // MARK: - Lifecycle

    func start(configuration: ServerConfiguration) {
        stop()
        lock.withLock { _configuration = configuration }
        state = .starting

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            state = .failed("Invalid port \(configuration.port).")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Responses are small JSON blobs; waiting on Nagle just adds delay.
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }

        do {
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self else { return }
                switch listenerState {
                case .ready:
                    let bound = listener.port?.rawValue ?? configuration.port
                    self.log.info("listening on port \(bound, privacy: .public)")
                    self.state = .running(port: bound)
                case .failed(let error):
                    self.log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .idle
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        let active = lock.withLock { () -> [HTTPConnection] in
            let values = Array(connectionsByID.values)
            connectionsByID.removeAll()
            return values
        }
        for connection in active { connection.cancel() }

        if case .idle = state {} else { state = .idle }
    }

    func restart(configuration: ServerConfiguration) {
        start(configuration: configuration)
    }

    // MARK: - Accepting

    private func accept(_ nwConnection: NWConnection) {
        guard isAllowed(nwConnection) else {
            log.notice("rejected non-local connection from \(String(describing: nwConnection.endpoint), privacy: .public)")
            nwConnection.cancel()
            return
        }

        let connection = HTTPConnection(
            connection: nwConnection,
            router: router,
            log: log,
            onFinished: { [weak self] finished in
                guard let self else { return }
                self.lock.withLock { _ = self.connectionsByID.removeValue(forKey: ObjectIdentifier(finished)) }
            }
        )
        lock.withLock { connectionsByID[ObjectIdentifier(connection)] = connection }
        connection.start()
    }

    private func isAllowed(_ connection: NWConnection) -> Bool {
        guard configuration.accessMode == .usbOnly else { return true }
        guard case .hostPort(let host, _) = connection.endpoint else {
            // Unknown endpoint shape; be conservative.
            return false
        }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || address.asIPv4?.isLoopback == true
        default:
            return false
        }
    }

    // MARK: - Auth

    /// Throws unless the request satisfies the configured token, if any.
    func authorize(_ request: HTTPRequest) throws {
        guard let token = configuration.authToken, !token.isEmpty else { return }
        guard let header = request.header("authorization") else {
            throw APIError.unauthorized("Missing Authorization header.")
        }
        let expected = "bearer \(token)".lowercased()
        guard header.lowercased() == expected else {
            throw APIError.unauthorized("Invalid bearer token.")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
