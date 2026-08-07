import AVFoundation
import Foundation
import UIKit
import os

/// Maps requests onto the capture controller and the recording store.
///
/// Handlers run on the originating connection's queue and may block (stopping a
/// recording waits for the asset writer to finalise); each connection has its own
/// queue, so a slow handler never stalls another client.
final class Router: @unchecked Sendable {
    private let capture: () -> CaptureController
    private let store: RecordingStore
    private let mjpeg: MJPEGBroadcaster
    private let events: EventBroadcaster
    private let log = Logger(subsystem: "cameraapi", category: "router")
    private let startedAt = Date()

    private weak var server: HTTPServer?

    /// Applied when a client asks the server to rebind. Set by the app so the UI
    /// and the persisted settings stay in step.
    var onServerSettingsChange: (@Sendable (ServerConfiguration) -> Void)?

    /// `capture` is a closure because the controller and the router are mutually
    /// dependent and the server must exist before the session starts.
    init(
        capture: @escaping () -> CaptureController,
        store: RecordingStore,
        mjpeg: MJPEGBroadcaster,
        events: EventBroadcaster
    ) {
        self.capture = capture
        self.store = store
        self.mjpeg = mjpeg
        self.events = events
    }

    func attach(server: HTTPServer) {
        self.server = server
    }

    // MARK: - Dispatch

    func route(_ request: HTTPRequest) throws -> HTTPResponse {
        let components = request.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // HEAD is answered exactly like GET; the connection suppresses the body.
        let method = request.method == "HEAD" ? "GET" : request.method

        let route = components.joined(separator: "/")

        // `/health` stays reachable without a token so a supervisor can probe it.
        if method == "GET", route == "health" {
            return .json(AcknowledgementDTO(ok: true, message: "CameraAPI \(ServerInfo.version)"))
        }

        try server?.authorize(request)

        // Routes carrying a recording id are matched positionally.
        if components.first == "files", components.count > 1 {
            return try fileRoute(method: method, components: components, request: request)
        }

        switch (method, route) {
        case ("GET", ""):
            return .text(Self.indexPage, contentType: "text/plain; charset=utf-8")

        case ("GET", "status"):
            return .json(status())

        case ("GET", "clock"):
            // Deliberately the cheapest handler in the router: every microsecond
            // spent here widens the uncertainty of the caller's offset estimate.
            return .json(capture().clockReading())

        case ("GET", "cameras"):
            return .json(["cameras": capture().cameraDescriptors()])

        case ("GET", "formats"):
            return .json(try capture().formats(cameraSelector: request.queryString("camera")))

        case ("POST", "configure"):
            return try configure(request)

        case ("GET", "controls"):
            return .json(capture().controlState())

        case ("POST", "control"):
            let body = try request.decodeBody(ControlRequest.self)
            return .json(try capture().applyControls(body))

        case ("GET", "record"):
            guard let progress = capture().recordingProgress else {
                return .json(AcknowledgementDTO(ok: true, message: "No recording in progress."))
            }
            return .json(progress)

        case ("POST", "record/start"):
            return try startRecording(request)

        case ("POST", "record/stop"):
            let timeout = request.queryDouble("timeout") ?? 30
            return .json(try capture().stopRecording(timeout: timeout))

        case ("GET", "files"):
            let recordings = store.list()
            return .json(RecordingListDTO(
                recordings: recordings,
                totalBytes: recordings.reduce(0) { $0 + $1.sizeBytes },
                freeDiskBytes: store.freeDiskBytes()
            ))

        case ("DELETE", "files"):
            guard request.queryBool("confirm") == true else {
                throw APIError.badRequest("Deleting every recording requires ?confirm=true.")
            }
            return .json(store.deleteAll())

        case ("GET", "snapshot"):
            return try snapshot(request)

        case ("GET", "stream.mjpeg"), ("GET", "stream"):
            return streamMJPEG(request)

        case ("POST", "stream/settings"):
            let body = try request.decodeBody(StreamSettingsRequest.self)
            var settings = capture().streamSettings
            if let fps = body.fps { settings.fps = fps }
            if let quality = body.quality { settings.quality = quality }
            if let maxWidth = body.maxWidth { settings.maxWidth = maxWidth }
            capture().streamSettings = settings
            return .json(streamState())

        case ("GET", "events"):
            return streamEvents()

        case ("POST", "server/settings"):
            return try updateServerSettings(request)

        default:
            throw APIError.notFound("No route for \(request.method) \(request.path). GET / lists the available endpoints.")
        }
    }

    private func fileRoute(method: String, components: [String], request: HTTPRequest) throws -> HTTPResponse {
        let id = components[1]

        switch (method, components.count) {
        case ("GET", 2):
            guard let recording = store.recording(id: id) else {
                throw APIError.notFound("No recording with id '\(id)'.")
            }
            return .json(recording)

        case ("DELETE", 2):
            let freed = try store.delete(id: id)
            return .json(DeleteResultDTO(deleted: [id], freedBytes: freed))

        case ("GET", 3) where components[2] == "download":
            return try download(id: id, request: request)

        default:
            throw APIError.notFound("No route for \(request.method) \(request.path). GET / lists the available endpoints.")
        }
    }

    // MARK: - Handlers

    private func configure(_ request: HTTPRequest) throws -> HTTPResponse {
        let body = try request.decodeBody(ConfigureRequest.self)
        var config = capture().configuration

        if let camera = body.camera { config.cameraSelector = camera }
        if let width = body.width {
            guard width > 0 else { throw APIError.badRequest("width must be positive.") }
            config.width = width
        }
        if let height = body.height {
            guard height > 0 else { throw APIError.badRequest("height must be positive.") }
            config.height = height
        }
        if let fps = body.fps {
            guard fps > 0, fps <= 240 else { throw APIError.badRequest("fps must be between 0 and 240.") }
            config.fps = fps
        }
        if let codec = body.codec { config.codec = try VideoCodec.parse(codec) }
        if let bitrate = body.bitrate {
            guard bitrate >= 100_000 else { throw APIError.badRequest("bitrate must be at least 100000 bits per second.") }
            config.explicitBitrate = bitrate
        }
        if let audio = body.audio { config.audioEnabled = audio }
        if let rotation = body.rotationDegrees {
            config.rotationDegrees = try CaptureConfiguration.validateRotation(rotation)
        }
        if let stabilization = body.stabilization {
            config.stabilization = try StabilizationMode.parse(stabilization)
        }
        if let interval = body.keyFrameInterval {
            guard (1...600).contains(interval) else {
                throw APIError.badRequest("keyFrameInterval must be between 1 (all-intra) and 600 frames.")
            }
            config.explicitKeyFrameInterval = interval
        }
        // An explicit format index only applies to this call; leaving it set would
        // silently pin the format across later resolution changes.
        config.formatIndex = body.formatIndex

        try capture().configure(config)
        return .json(status())
    }

    private func startRecording(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: RecordStartRequest
        if request.body.isEmpty {
            body = RecordStartRequest()
        } else {
            body = try request.decodeBody(RecordStartRequest.self)
        }
        let container = try body.container.map { try MediaContainer.parse($0) } ?? .mov
        let dto = try capture().startRecording(
            name: body.name,
            container: container,
            maxDurationSeconds: body.maxDurationSeconds
        )
        return .json(dto, status: 201)
    }

    private func download(id: String, request: HTTPRequest) throws -> HTTPResponse {
        guard let recording = store.recording(id: id) else {
            throw APIError.notFound("No recording with id '\(id)'.")
        }
        let url = store.mediaURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw APIError.notFound("Media file for '\(id)' is missing from disk.")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let container = MediaContainer(rawValue: recording.container) ?? .mov

        var headers = [
            "Content-Type": container.mimeType,
            "Content-Disposition": "attachment; filename=\"\(recording.name).\(recording.container)\"",
        ]

        var range: HTTPByteRange?
        var status = 200
        if let rangeHeader = request.header("range") {
            guard let parsed = HTTPByteRange.parse(rangeHeader, totalSize: totalSize) else {
                headers["Content-Range"] = "bytes */\(totalSize)"
                throw APIError.rangeNotSatisfiable("Could not satisfy Range '\(rangeHeader)' for a \(totalSize) byte file.")
            }
            range = parsed
            status = 206
        }

        return HTTPResponse(
            status: status,
            headers: headers,
            body: .file(url: url, range: range, totalSize: totalSize)
        )
    }

    private func snapshot(_ request: HTTPRequest) throws -> HTTPResponse {
        let maxWidth = request.queryInt("maxWidth") ?? 1920
        let quality = request.queryDouble("quality") ?? 0.85
        let timeout = request.queryDouble("timeout") ?? 5

        guard maxWidth >= 64, maxWidth <= 8192 else {
            throw APIError.badRequest("maxWidth must be between 64 and 8192.")
        }
        guard quality > 0, quality <= 1 else {
            throw APIError.badRequest("quality must be between 0 and 1.")
        }

        let data = try capture().snapshot(maxWidth: maxWidth, quality: quality, timeout: timeout)
        return HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": "image/jpeg",
                "Cache-Control": "no-store",
            ],
            body: .data(data)
        )
    }

    private func streamMJPEG(_ request: HTTPRequest) -> HTTPResponse {
        // Query parameters adjust the shared stream settings so a client can dial
        // in quality with nothing but a URL.
        var settings = capture().streamSettings
        if let fps = request.queryDouble("fps") { settings.fps = fps }
        if let quality = request.queryDouble("quality") { settings.quality = quality }
        if let maxWidth = request.queryInt("maxWidth") { settings.maxWidth = maxWidth }
        capture().streamSettings = settings

        let broadcaster = mjpeg
        return HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": MJPEGBroadcaster.contentType,
                "Cache-Control": "no-store",
                "Pragma": "no-cache",
            ],
            body: .hijack { writer in
                broadcaster.add(writer)
            }
        )
    }

    private func streamEvents() -> HTTPResponse {
        let broadcaster = events
        let snapshot = status()
        return HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": EventBroadcaster.contentType,
                "Cache-Control": "no-store",
                "X-Accel-Buffering": "no",
            ],
            body: .hijack { writer in
                broadcaster.add(writer)
                // Prime the stream so a client knows the current state immediately.
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let envelope = EventEnvelope(type: "hello", timestamp: Date(), payload: snapshot)
                if let data = try? encoder.encode(envelope), let json = String(data: data, encoding: .utf8) {
                    writer.write(Data("event: hello\ndata: \(json)\n\n".utf8))
                }
            }
        )
    }

    private func updateServerSettings(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let server else {
            throw APIError.internalError("Server is not attached.")
        }
        let body = try request.decodeBody(ServerSettingsRequest.self)
        var config = server.configuration

        if let port = body.port {
            guard (1024...65535).contains(port) else {
                throw APIError.badRequest("port must be between 1024 and 65535.")
            }
            config.port = UInt16(port)
        }
        if let mode = body.accessMode {
            guard let parsed = AccessMode(rawValue: mode) else {
                throw APIError.badRequest("accessMode must be 'usb_only' or 'network'.")
            }
            config.accessMode = parsed
        }
        if let token = body.authToken {
            config.authToken = token.isEmpty ? nil : token
        }

        let response = HTTPResponse.json(AcknowledgementDTO(
            ok: true,
            message: "Server rebinding to port \(config.port) in \(config.accessMode.rawValue) mode. Existing connections will drop."
        ))

        // Restart after the response has had time to flush; rebinding tears down
        // this very connection.
        let updated = config
        let handler = onServerSettingsChange
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            handler?(updated)
        }

        return response
    }

    // MARK: - Status assembly

    func status() -> StatusResponseDTO {
        let controller = capture()
        let recordings = store.list()
        let serverConfig = server?.configuration ?? ServerConfiguration()

        return StatusResponseDTO(
            api: APIInfoDTO(
                name: "CameraAPI",
                version: ServerInfo.version,
                uptimeSeconds: Date().timeIntervalSince(startedAt),
                port: Int(serverConfig.port),
                accessMode: serverConfig.accessMode.rawValue,
                authRequired: !(serverConfig.authToken ?? "").isEmpty,
                httpConnections: server?.activeConnectionCount ?? 0,
                mjpegClients: mjpeg.subscriberCount,
                eventClients: events.subscriberCount
            ),
            device: deviceInfo(),
            session: controller.sessionState(),
            controls: controller.controlState(),
            recording: controller.recordingProgress,
            stream: streamState(),
            storage: StorageDTO(
                recordingCount: recordings.count,
                totalBytes: recordings.reduce(0) { $0 + $1.sizeBytes },
                freeDiskBytes: store.freeDiskBytes()
            )
        )
    }

    private func streamState() -> StreamStateDTO {
        let settings = capture().streamSettings
        return StreamStateDTO(
            fps: settings.fps,
            quality: settings.quality,
            maxWidth: settings.maxWidth,
            clients: mjpeg.subscriberCount
        )
    }

    private func deviceInfo() -> DeviceInfoDTO {
        let device = DeviceSnapshot.current()
        return DeviceInfoDTO(
            name: device.name,
            model: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            thermalState: Self.name(for: ProcessInfo.processInfo.thermalState),
            batteryLevel: device.batteryLevel,
            batteryState: device.batteryState,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            freeDiskBytes: store.freeDiskBytes()
        )
    }

    private static func name(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Index

    private static let indexPage = """
    CameraAPI \(ServerInfo.version)

    Control and record the iPhone camera over HTTP. Reach this server from Linux with:
        iproxy 8080:8080 &
        curl http://localhost:8080/status

    DISCOVERY
      GET    /health                      Liveness probe (never requires auth)
      GET    /status                      Full state: device, session, controls, recording, storage
      GET    /clock                       Capture-clock reading for aligning video PTS to an external timeline
      GET    /cameras                     Available capture devices
      GET    /formats[?camera=<id>]       Every resolution/frame-rate combination a camera supports

    CONFIGURATION
      POST   /configure                   {camera,width,height,fps,codec,bitrate,audio,rotationDegrees,
                                           stabilization,formatIndex,keyFrameInterval}
      GET    /controls                    Current focus/exposure/white balance/zoom/torch
      POST   /control                     {focus,exposure,whiteBalance,zoom,torch}
      POST   /stream/settings             {fps,quality,maxWidth}
      POST   /server/settings             {port,accessMode,authToken}

    RECORDING
      POST   /record/start                {name,container,maxDurationSeconds} -> 201 with recording id
      POST   /record/stop[?timeout=30]    Finalises the file and returns its metadata
      GET    /record                      Progress of the in-flight recording

    FILES
      GET    /files                       List finished recordings
      GET    /files/<id>                  Metadata for one recording
      GET    /files/<id>/download         The media file (supports HTTP Range)
      DELETE /files/<id>                  Delete one recording
      DELETE /files?confirm=true          Delete every recording

    LIVE
      GET    /snapshot[?maxWidth&quality] Single JPEG from the next frame
      GET    /stream.mjpeg[?fps&quality&maxWidth]  multipart/x-mixed-replace JPEG stream
      GET    /events                      Server-sent events: recording.started, recording.stopped,
                                          recording.autostopped, session.interrupted, session.resumed, error

    """
}

/// `UIDevice` is main-actor isolated; this caches the parts the API reports so
/// status can be assembled from any thread.
struct DeviceSnapshot: Sendable {
    var name: String
    var model: String
    var systemName: String
    var systemVersion: String
    var batteryLevel: Double?
    var batteryState: String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = DeviceSnapshot(
        name: "unknown",
        model: "unknown",
        systemName: "iOS",
        systemVersion: "unknown",
        batteryLevel: nil,
        batteryState: "unknown"
    )

    static func current() -> DeviceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    @MainActor
    static func refresh() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let level = device.batteryLevel
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        case .unknown: batteryState = "unknown"
        @unknown default: batteryState = "unknown"
        }

        let snapshot = DeviceSnapshot(
            name: device.name,
            model: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            batteryLevel: level < 0 ? nil : Double(level),
            batteryState: batteryState
        )

        lock.lock()
        cached = snapshot
        lock.unlock()
    }
}
