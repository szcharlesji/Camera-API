import AVFoundation
import Foundation
import Observation
import SwiftUI
import os

/// Wires the capture stack to the HTTP server and exposes just enough state for
/// the on-device dashboard.
@MainActor
@Observable
final class AppServices {
    let store = RecordingStore()
    let mjpeg = MJPEGBroadcaster()
    let events = EventBroadcaster()
    let router: Router
    let server: HTTPServer
    let capture: CaptureController

    // MARK: - Published state

    private(set) var serverState: HTTPServer.State = .idle
    private(set) var isRecording = false
    private(set) var recordingSummary: String = "Idle"
    private(set) var sessionSummary: String = "Not configured"
    private(set) var storageSummary: String = ""
    private(set) var streamClients = 0
    private(set) var eventClients = 0
    private(set) var permissionsGranted = false
    private(set) var logLines: [LogLine] = []

    var port: Int {
        didSet { persistAndRestart() }
    }
    var accessMode: AccessMode {
        didSet { persistAndRestart() }
    }
    var authToken: String {
        didSet { persistAndRestart() }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private let log = Logger(subsystem: "cameraapi", category: "app")
    private var refreshTimer: Timer?
    private var heartbeatTick = 0

    private enum Keys {
        static let port = "server.port"
        static let accessMode = "server.accessMode"
        static let authToken = "server.authToken"
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        let storedPort = defaults.integer(forKey: Keys.port)
        port = (1024...65535).contains(storedPort) ? storedPort : 8080
        accessMode = defaults.string(forKey: Keys.accessMode).flatMap(AccessMode.init(rawValue:)) ?? .usbOnly
        authToken = defaults.string(forKey: Keys.authToken) ?? ""

        let store = self.store
        let mjpeg = self.mjpeg
        let events = self.events

        // The router needs the controller and the controller needs the
        // broadcasters, so the controller is handed over through a box the
        // router reads lazily.
        let box = ControllerBox()
        router = Router(capture: { box.controller! }, store: store, mjpeg: mjpeg, events: events)
        capture = CaptureController(store: store, mjpeg: mjpeg, events: events)
        box.controller = capture
        server = HTTPServer(router: router)

        store.pruneOrphans()
        configureCallbacks()
    }

    /// Breaks the initialisation cycle between `Router` and `CaptureController`.
    private final class ControllerBox: @unchecked Sendable {
        var controller: CaptureController?
    }

    private func configureCallbacks() {
        server.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.serverState = state
                switch state {
                case .running(let port):
                    self.append(log: "HTTP server listening on port \(port) (\(self.accessMode.rawValue))")
                case .failed(let message):
                    self.append(log: "Server failed: \(message)")
                case .idle:
                    self.append(log: "Server stopped")
                case .starting:
                    break
                }
            }
        }

        capture.onRecordingChange = { [weak self] recording in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRecording = recording
                self.append(log: recording ? "Recording started" : "Recording stopped")
                self.refresh()
            }
        }

        router.onServerSettingsChange = { [weak self] configuration in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.port = Int(configuration.port)
                self.accessMode = configuration.accessMode
                self.authToken = configuration.authToken ?? ""
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        // A capture rig should never sleep mid-session.
        UIApplication.shared.isIdleTimerDisabled = true
        DeviceSnapshot.refresh()

        startServer()

        capture.requestPermissions { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionsGranted = granted
                if granted {
                    self.append(log: "Camera access granted")
                    self.capture.startSession()
                } else {
                    self.append(log: "Camera access denied — grant it in Settings, then relaunch")
                }
                self.refresh()
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        server.stop()
        capture.stopSession()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startServer() {
        server.start(configuration: ServerConfiguration(
            port: UInt16(port),
            accessMode: accessMode,
            authToken: authToken.isEmpty ? nil : authToken
        ))
    }

    private func persistAndRestart() {
        let defaults = UserDefaults.standard
        defaults.set(port, forKey: Keys.port)
        defaults.set(accessMode.rawValue, forKey: Keys.accessMode)
        defaults.set(authToken, forKey: Keys.authToken)
        startServer()
    }

    // MARK: - Refresh

    private func tick() {
        heartbeatTick += 1
        // A comment every 15s keeps idle SSE connections from being reaped.
        if heartbeatTick % 15 == 0 {
            events.sendComment("keepalive")
            DeviceSnapshot.refresh()
        }
        refresh()
    }

    private func refresh() {
        let session = capture.sessionState()
        if session.running {
            let config = session.config
            sessionSummary = "\(config.width)×\(config.height) @ \(Int(config.fps.rounded())) fps · \(config.codec.uppercased()) · \(config.bitrate / 1_000_000) Mbps"
        } else if let error = session.lastError {
            sessionSummary = "Stopped — \(error)"
        } else {
            sessionSummary = "Session not running"
        }

        if let progress = capture.recordingProgress {
            let duration = String(format: "%.1f", progress.durationSeconds)
            let megabytes = String(format: "%.1f", Double(progress.bytesWritten) / 1_000_000)
            recordingSummary = "\(progress.name) · \(duration)s · \(progress.framesWritten) frames · \(megabytes) MB"
        } else {
            recordingSummary = "Idle"
        }

        let recordings = store.list()
        let totalMB = Double(recordings.reduce(0) { $0 + $1.sizeBytes }) / 1_000_000
        let freeGB = store.freeDiskBytes().map { Double($0) / 1_000_000_000 }
        storageSummary = String(format: "%d recording%@ · %.1f MB used", recordings.count, recordings.count == 1 ? "" : "s", totalMB)
        if let freeGB {
            storageSummary += String(format: " · %.1f GB free", freeGB)
        }

        streamClients = mjpeg.subscriberCount
        eventClients = events.subscriberCount
    }

    private func append(log message: String) {
        logLines.append(LogLine(timestamp: Date(), message: message))
        if logLines.count > 100 {
            logLines.removeFirst(logLines.count - 100)
        }
    }

    // MARK: - Helpers for the UI

    var serverStateText: String {
        switch serverState {
        case .idle: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Listening on :\(port)"
        case .failed(let message): return "Failed — \(message)"
        }
    }

    var serverIsHealthy: Bool {
        if case .running = serverState { return true }
        return false
    }

    var iproxyCommand: String {
        "iproxy \(port):\(port)"
    }
}
