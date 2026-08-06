import Foundation
import Network
import os

/// One client connection. All mutable state is confined to `queue`; the
/// `HTTPResponseWriter` methods hop onto it because streaming handlers push
/// frames in from capture threads.
final class HTTPConnection: HTTPResponseWriter, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let router: Router
    private let log: Logger
    private let onFinished: @Sendable (HTTPConnection) -> Void

    private var parser = HTTPRequestParser()
    private var closeHandlers: [@Sendable () -> Void] = []
    private var open = true
    /// Set once a handler takes ownership of the socket, which stops the request loop.
    private var hijacked = false

    /// 256 KiB balances syscall overhead against sitting on a big buffer per client.
    private static let fileChunkSize = 256 * 1024

    var isOpen: Bool {
        queue.sync { open }
    }

    init(
        connection: NWConnection,
        router: Router,
        log: Logger,
        onFinished: @escaping @Sendable (HTTPConnection) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.log = log
        self.onFinished = onFinished
        self.queue = DispatchQueue(label: "cameraapi.connection.\(UUID().uuidString.prefix(8))")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.teardown() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        queue.async {
            guard self.open else { return }
            self.connection.cancel()
            self.teardown()
        }
    }

    // MARK: - Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Already on `queue` — NWConnection delivers callbacks on its start queue.
            if let error {
                self.log.debug("receive error: \(error.localizedDescription, privacy: .public)")
                self.connection.cancel()
                self.teardown()
                return
            }

            if let data, !data.isEmpty {
                self.parser.append(data)
                do {
                    try self.drainRequests()
                } catch {
                    self.sendParseFailure(error)
                    return
                }
            }

            if isComplete {
                self.connection.cancel()
                self.teardown()
                return
            }

            guard self.open, !self.hijacked else { return }
            self.receive()
        }
    }

    private func drainRequests() throws {
        while !hijacked, open, let request = try parser.next() {
            handle(request)
            // A hijacked or closing response owns the socket from here on.
            if hijacked || !open { return }
        }
    }

    private func sendParseFailure(_ error: Error) {
        let apiError: APIError
        switch error {
        case HTTPRequestParser.ParseError.headersTooLarge:
            apiError = APIError(status: 431, code: "headers_too_large", message: "Request headers exceeded 64 KiB.")
        case HTTPRequestParser.ParseError.bodyTooLarge:
            apiError = APIError(status: 413, code: "body_too_large", message: "Request body exceeded 4 MiB.")
        case HTTPRequestParser.ParseError.unsupportedTransferEncoding:
            apiError = APIError.badRequest("Chunked request bodies are not supported; send Content-Length.")
        default:
            apiError = APIError.badRequest("Malformed HTTP request.")
        }
        write(response: .error(apiError), keepAlive: false)
    }

    // MARK: - Dispatch

    private func handle(_ request: HTTPRequest) {
        let response: HTTPResponse
        do {
            response = try router.route(request)
        } catch let error as APIError {
            response = .error(error)
        } catch {
            log.error("unhandled handler error: \(String(describing: error), privacy: .public)")
            response = .error(.internalError(String(describing: error)))
        }

        let keepAlive = request.wantsKeepAlive && !isStreaming(response)
        write(response: response, keepAlive: keepAlive, isHeadRequest: request.method == "HEAD")
    }

    private func isStreaming(_ response: HTTPResponse) -> Bool {
        if case .hijack = response.body { return true }
        return false
    }

    // MARK: - Writing

    private func write(response: HTTPResponse, keepAlive: Bool, isHeadRequest: Bool = false) {
        var headers = response.headers
        headers["Server"] = "CameraAPI/\(ServerInfo.version)"
        headers["Date"] = Self.httpDate()

        switch response.body {
        case .empty:
            headers["Content-Length"] = "0"
        case .data(let data):
            headers["Content-Length"] = String(data.count)
        case .file(_, let range, let totalSize):
            headers["Accept-Ranges"] = "bytes"
            if let range {
                headers["Content-Length"] = String(range.length)
                headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(totalSize)"
            } else {
                headers["Content-Length"] = String(totalSize)
            }
        case .hijack:
            // Length is unknown; the handler streams until the peer disconnects.
            headers["Connection"] = "close"
            headers["Cache-Control"] = "no-store"
        }

        if case .hijack = response.body {} else {
            headers["Connection"] = keepAlive ? "keep-alive" : "close"
        }

        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrase(for: response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        let headData = Data(head.utf8)

        switch response.body {
        case .empty:
            send(headData) { [weak self] ok in
                self?.finishRequest(keepAlive: keepAlive, succeeded: ok)
            }

        case .data(let payload):
            let combined = isHeadRequest ? headData : headData + payload
            send(combined) { [weak self] ok in
                self?.finishRequest(keepAlive: keepAlive, succeeded: ok)
            }

        case .file(let url, let range, let totalSize):
            send(headData) { [weak self] ok in
                guard let self else { return }
                guard ok, !isHeadRequest else {
                    self.finishRequest(keepAlive: keepAlive, succeeded: ok)
                    return
                }
                let effective = range ?? HTTPByteRange(start: 0, end: max(totalSize, 1) - 1)
                self.streamFile(at: url, range: effective, keepAlive: keepAlive)
            }

        case .hijack(let handler):
            hijacked = true
            send(headData) { [weak self] ok in
                guard let self else { return }
                guard ok else {
                    self.connection.cancel()
                    self.teardown()
                    return
                }
                handler(self)
            }
        }
    }

    private func finishRequest(keepAlive: Bool, succeeded: Bool) {
        guard succeeded, keepAlive, open else {
            connection.cancel()
            teardown()
            return
        }
        // Another pipelined request may already be buffered.
        do {
            try drainRequests()
        } catch {
            sendParseFailure(error)
        }
    }

    private func streamFile(at url: URL, range: HTTPByteRange, keepAlive: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            connection.cancel()
            teardown()
            return
        }
        do {
            try handle.seek(toOffset: range.start)
        } catch {
            try? handle.close()
            connection.cancel()
            teardown()
            return
        }

        pumpFile(FileCursor(handle: handle, remaining: range.length), keepAlive: keepAlive)
    }

    /// Sends the next chunk, then re-enters from the send completion so the file
    /// is read at the rate the peer drains it.
    private func pumpFile(_ cursor: FileCursor, keepAlive: Bool) {
        guard open, cursor.remaining > 0 else {
            cursor.close()
            finishRequest(keepAlive: keepAlive, succeeded: true)
            return
        }

        let wanted = Int(min(cursor.remaining, UInt64(Self.fileChunkSize)))
        let chunk = (try? cursor.handle.read(upToCount: wanted)) ?? Data()
        guard !chunk.isEmpty else {
            // File shrank underneath us; the declared Content-Length can no
            // longer be met, so drop the connection rather than hang the client.
            cursor.close()
            connection.cancel()
            teardown()
            return
        }
        cursor.remaining -= UInt64(chunk.count)

        send(chunk) { [weak self] ok in
            guard let self, ok else {
                cursor.close()
                return
            }
            self.pumpFile(cursor, keepAlive: keepAlive)
        }
    }

    /// Read position for an in-flight file response. A reference box because the
    /// send completions that advance it look concurrent to the compiler, even
    /// though they are all serialised on `queue`.
    private final class FileCursor: @unchecked Sendable {
        let handle: FileHandle
        var remaining: UInt64

        init(handle: FileHandle, remaining: UInt64) {
            self.handle = handle
            self.remaining = remaining
        }

        func close() {
            try? handle.close()
        }
    }

    /// Low-level send. The completion always runs on `queue`.
    private func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        guard open else {
            completion(false)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else {
                completion(false)
                return
            }
            if let error {
                self.log.debug("send error: \(error.localizedDescription, privacy: .public)")
                self.connection.cancel()
                self.teardown()
                completion(false)
            } else {
                completion(true)
            }
        })
    }

    private func teardown() {
        guard open else { return }
        open = false
        let handlers = closeHandlers
        closeHandlers = []
        for handler in handlers { handler() }
        onFinished(self)
    }

    // MARK: - HTTPResponseWriter

    func write(_ data: Data, completion: (@Sendable (Bool) -> Void)?) {
        queue.async {
            guard self.open else {
                completion?(false)
                return
            }
            self.send(data) { ok in completion?(ok) }
        }
    }

    func finish() {
        cancel()
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            guard self.open else {
                handler()
                return
            }
            self.closeHandlers.append(handler)
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func httpDate() -> String {
        dateFormatter.string(from: Date())
    }
}

enum ServerInfo {
    static let version = "1.0.0"
}
