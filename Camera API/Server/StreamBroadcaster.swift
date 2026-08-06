import Foundation

/// A single connected streaming client.
///
/// Each subscriber carries its own in-flight budget. If a client reads more
/// slowly than frames are produced, its excess frames are dropped rather than
/// queued — a stalled viewer must never grow memory or hold back the recorder.
private final class StreamSubscriber: @unchecked Sendable {
    let id = UUID()
    let writer: any HTTPResponseWriter

    private let lock = NSLock()
    private var inFlight = 0
    private let maxInFlight: Int
    private(set) var droppedCount = 0

    init(writer: any HTTPResponseWriter, maxInFlight: Int) {
        self.writer = writer
        self.maxInFlight = maxInFlight
    }

    /// Returns `false` if the payload was dropped because the client is behind.
    @discardableResult
    func offer(_ data: Data) -> Bool {
        let accepted: Bool = lock.withLock {
            guard inFlight < maxInFlight else {
                droppedCount += 1
                return false
            }
            inFlight += 1
            return true
        }
        guard accepted else { return false }

        writer.write(data) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.inFlight = max(0, self.inFlight - 1) }
        }
        return true
    }
}

/// Fans a byte stream out to any number of connected clients.
class StreamBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: StreamSubscriber] = [:]
    private let maxInFlight: Int

    /// Called whenever the client count changes, so capture work can be skipped
    /// entirely when nobody is watching.
    var onSubscriberCountChange: (@Sendable (Int) -> Void)?

    init(maxInFlight: Int = 2) {
        self.maxInFlight = maxInFlight
    }

    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    var hasSubscribers: Bool { subscriberCount > 0 }

    func add(_ writer: any HTTPResponseWriter) {
        let subscriber = StreamSubscriber(writer: writer, maxInFlight: maxInFlight)
        let count: Int = lock.withLock {
            subscribers[subscriber.id] = subscriber
            return subscribers.count
        }
        onSubscriberCountChange?(count)

        writer.onClose { [weak self] in
            guard let self else { return }
            let remaining: Int = self.lock.withLock {
                self.subscribers.removeValue(forKey: subscriber.id)
                return self.subscribers.count
            }
            self.onSubscriberCountChange?(remaining)
        }
    }

    func broadcast(_ data: Data) {
        let current: [StreamSubscriber] = lock.withLock { Array(subscribers.values) }
        for subscriber in current {
            guard subscriber.writer.isOpen else { continue }
            subscriber.offer(data)
        }
    }

    func closeAll() {
        let current: [StreamSubscriber] = lock.withLock {
            let values = Array(subscribers.values)
            subscribers.removeAll()
            return values
        }
        for subscriber in current { subscriber.writer.finish() }
        onSubscriberCountChange?(0)
    }
}

// MARK: - MJPEG

/// Emits `multipart/x-mixed-replace`, the format ffmpeg, OpenCV, VLC and browsers
/// all consume without any client-side code.
final class MJPEGBroadcaster: StreamBroadcaster, @unchecked Sendable {
    static let boundary = "cameraapiframe"

    static var contentType: String {
        "multipart/x-mixed-replace; boundary=\(boundary)"
    }

    func send(jpeg: Data) {
        var part = Data()
        part.append(Data("--\(Self.boundary)\r\n".utf8))
        part.append(Data("Content-Type: image/jpeg\r\n".utf8))
        part.append(Data("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        broadcast(part)
    }
}

// MARK: - Server-sent events

/// Emits `text/event-stream`. Chosen over WebSocket because it needs no framing
/// layer on either side: `curl -N` and a plain socket read both work.
final class EventBroadcaster: StreamBroadcaster, @unchecked Sendable {
    static let contentType = "text/event-stream; charset=utf-8"

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Events are small and ordered; allow a deeper queue than video frames so a
    /// brief client stall does not silently lose a `recording.stopped`.
    init() {
        super.init(maxInFlight: 32)
    }

    func send(event: String, payload: some Encodable) {
        guard hasSubscribers else { return }
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var frame = "event: \(event)\n"
        // A payload must never contain a raw newline mid-field; encoded JSON never does.
        frame += "data: \(json)\n\n"
        broadcast(Data(frame.utf8))
    }

    func sendComment(_ text: String) {
        guard hasSubscribers else { return }
        broadcast(Data(": \(text)\n\n".utf8))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
