import AVFoundation
import CoreMedia
import Foundation
import UIKit
import os

/// Owns the capture session, the asset writer, and the taps that feed the MJPEG
/// stream and `/snapshot`.
///
/// Threading model:
///   * `sessionQueue` serialises session and device configuration.
///   * `sampleQueue` receives *both* video and audio buffers and is the only
///     queue that touches the asset writer, so no lock is needed around it.
///   * `stateLock` guards the small snapshot of state that HTTP handlers read.
final class CaptureController: NSObject, @unchecked Sendable {

    // MARK: - Nested types

    /// A recording in flight. Confined to `sampleQueue` once installed.
    private final class ActiveRecording {
        let id: String
        let name: String
        let container: MediaContainer
        let url: URL
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let startedAt: Date
        let configuration: CaptureConfiguration
        let encodedWidth: Int
        let encodedHeight: Int
        let maxDurationSeconds: Double?

        var sessionStarted = false
        var firstPTS: CMTime = .invalid
        var lastPTS: CMTime = .invalid
        var framesWritten = 0
        var captureDrops = 0
        var writerBackpressureDrops = 0
        var appendFailures = 0
        /// Emitted exactly once, when the first sample establishes the anchor.
        var firstFrameAnnounced = false

        var framesDropped: Int { captureDrops + writerBackpressureDrops + appendFailures }

        init(
            id: String,
            name: String,
            container: MediaContainer,
            url: URL,
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            audioInput: AVAssetWriterInput?,
            configuration: CaptureConfiguration,
            encodedWidth: Int,
            encodedHeight: Int,
            maxDurationSeconds: Double?
        ) {
            self.id = id
            self.name = name
            self.container = container
            self.url = url
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.startedAt = Date()
            self.configuration = configuration
            self.encodedWidth = encodedWidth
            self.encodedHeight = encodedHeight
            self.maxDurationSeconds = maxDurationSeconds
        }

        var durationSeconds: Double {
            guard sessionStarted, firstPTS.isValid, lastPTS.isValid else { return 0 }
            return max(0, CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS)))
        }
    }

    /// A pending `/snapshot`, fulfilled by the next video frame.
    private final class SnapshotRequest {
        let maxWidth: Int
        let quality: Double
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?

        init(maxWidth: Int, quality: Double) {
            self.maxWidth = maxWidth
            self.quality = quality
        }
    }

    // MARK: - Collaborators

    let session = AVCaptureSession()
    private let store: RecordingStore
    private let mjpeg: MJPEGBroadcaster
    private let events: EventBroadcaster
    private let jpegEncoder = JPEGEncoder()
    private let log = Logger(subsystem: "cameraapi", category: "capture")

    private let sessionQueue = DispatchQueue(label: "cameraapi.session")
    private let sampleQueue = DispatchQueue(label: "cameraapi.samples")

    // MARK: - Session objects (sessionQueue)

    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var outputsAttached = false

    // MARK: - Recording (sampleQueue)

    private var activeRecording: ActiveRecording?
    private var pendingSnapshots: [SnapshotRequest] = []
    private var lastStreamedFrameTime: CFTimeInterval = 0
    private var lastProgressPublish: CFTimeInterval = 0

    // MARK: - Shared state (stateLock)

    private let stateLock = NSLock()
    private var _configuration = CaptureConfiguration()
    private var _streamSettings = StreamSettings()
    private var _progress: ActiveRecordingDTO?
    private var _lastError: String?
    private var _interrupted = false
    private var _interruptionReason: String?
    /// Interruptions overlapping the current recording. Cleared at start; any
    /// entry means the footage has a gap.
    private var _recordingInterruptions: [InterruptionDTO] = []
    private var _activeFormatIndex = -1

    /// Fired when recording starts or stops so the UI can refresh promptly.
    var onRecordingChange: (@Sendable (Bool) -> Void)?

    // MARK: - Init

    init(store: RecordingStore, mjpeg: MJPEGBroadcaster, events: EventBroadcaster) {
        self.store = store
        self.mjpeg = mjpeg
        self.events = events
        super.init()
        registerNotifications()
    }

    // MARK: - Public state

    var configuration: CaptureConfiguration {
        stateLock.withLock { _configuration }
    }

    var streamSettings: StreamSettings {
        get { stateLock.withLock { _streamSettings } }
        set {
            var clamped = newValue
            clamped.clamp()
            stateLock.withLock { _streamSettings = clamped }
        }
    }

    var isRecording: Bool {
        stateLock.withLock { _progress != nil }
    }

    var recordingProgress: ActiveRecordingDTO? {
        stateLock.withLock { _progress }
    }

    var isCameraAvailable: Bool {
        videoDevice != nil
    }

    // MARK: - Permissions

    static func permissionStatusName(for mediaType: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    /// Requests camera (and, if enabled, microphone) access, then calls back.
    func requestPermissions(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else {
                completion(false)
                return
            }
            guard self.configuration.audioEnabled else {
                completion(videoGranted)
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // A denied microphone is not fatal: recording continues without audio.
                completion(videoGranted)
            }
        }
    }

    // MARK: - Session lifecycle

    /// Builds the session with the current configuration and starts it.
    func startSession() {
        sessionQueue.async {
            do {
                try self.applyConfigurationLocked(self.configuration)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.setLastError(nil)
            } catch let error as APIError {
                self.setLastError(error.message)
                self.log.error("session start failed: \(error.message, privacy: .public)")
            } catch {
                self.setLastError(error.localizedDescription)
                self.log.error("session start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Applies a new configuration, reporting failures synchronously to the caller.
    func configure(_ newConfiguration: CaptureConfiguration) throws {
        try sessionQueue.sync {
            guard !self.isRecording else {
                throw APIError.conflict("Cannot reconfigure while recording. Call POST /record/stop first.")
            }
            try self.applyConfigurationLocked(newConfiguration)
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.setLastError(nil)
        }
    }

    /// - Important: must run on `sessionQueue`.
    private func applyConfigurationLocked(_ requested: CaptureConfiguration) throws {
        var config = requested

        let device = try resolveDevice(selector: config.cameraSelector)

        session.beginConfiguration()
        // `inputPriority` stops the session from overriding the format we pick below.
        session.sessionPreset = .inputPriority

        // Swap the video input if the device changed.
        if videoDeviceInput?.device.uniqueID != device.uniqueID {
            if let existing = videoDeviceInput {
                session.removeInput(existing)
                videoDeviceInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    throw APIError.internalError("Session rejected camera '\(device.localizedName)'.")
                }
                session.addInput(input)
                videoDeviceInput = input
            } catch let error as APIError {
                throw error
            } catch {
                session.commitConfiguration()
                throw APIError.internalError("Could not open camera: \(error.localizedDescription)")
            }
        }
        videoDevice = device

        // Audio input follows the audio flag and the microphone permission.
        try configureAudioInputLocked(enabled: config.audioEnabled)
        if config.audioEnabled, audioDeviceInput == nil {
            // Permission denied or no microphone; record silently rather than fail.
            config.audioEnabled = false
        }

        attachOutputsLocked()

        // Choose the capture format.
        let formats = device.formats
        let selectedFormat: AVCaptureDevice.Format
        if let index = config.formatIndex {
            guard formats.indices.contains(index) else {
                session.commitConfiguration()
                throw APIError.badRequest("formatIndex \(index) is out of range; device has \(formats.count) formats. See GET /formats.")
            }
            selectedFormat = formats[index]
        } else {
            guard let match = FormatSelector.bestMatch(
                formats: formats,
                width: config.width,
                height: config.height,
                fps: config.fps
            ) else {
                session.commitConfiguration()
                let best = FormatSelector.maxFrameRate(formats: formats)
                throw APIError.badRequest(
                    "No format on '\(device.localizedName)' supports \(config.fps) fps (device maximum is \(best) fps). See GET /formats."
                )
            }
            selectedFormat = match
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = selectedFormat

            // Setting activeFormat resets frame duration, so pin it afterwards.
            let supported = selectedFormat.videoSupportedFrameRateRanges
            let clampedFps = clampFrameRate(config.fps, to: supported)
            let duration = CMTime(value: 1_000_000, timescale: Int32(clampedFps * 1_000_000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            config.fps = clampedFps

            device.unlockForConfiguration()
        } catch let error as APIError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw APIError.internalError("Could not lock camera for configuration: \(error.localizedDescription)")
        }

        // Report the dimensions actually in effect rather than what was asked for.
        let dimensions = selectedFormat.dimensions
        config.width = Int(dimensions.width)
        config.height = Int(dimensions.height)

        configureVideoConnectionLocked(rotationDegrees: config.rotationDegrees, stabilization: config.stabilization)

        session.commitConfiguration()

        let formatIndex = formats.firstIndex(of: selectedFormat) ?? -1
        stateLock.withLock {
            _configuration = config
            _activeFormatIndex = formatIndex
        }

        log.info("""
            configured \(device.localizedName, privacy: .public) \
            \(config.width, privacy: .public)x\(config.height, privacy: .public)@\(config.fps, privacy: .public) \
            codec=\(config.codec.rawValue, privacy: .public) rotation=\(config.rotationDegrees, privacy: .public)
            """)
    }

    private func clampFrameRate(_ fps: Double, to ranges: [AVFrameRateRange]) -> Double {
        guard let range = ranges.first(where: { fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01 })
                ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return fps
        }
        return min(max(fps, range.minFrameRate), range.maxFrameRate)
    }

    private func configureAudioInputLocked(enabled: Bool) throws {
        if !enabled {
            if let existing = audioDeviceInput {
                session.removeInput(existing)
                audioDeviceInput = nil
            }
            return
        }
        guard audioDeviceInput == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)
        audioDeviceInput = input
    }

    private func attachOutputsLocked() {
        guard !outputsAttached else { return }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Never let a slow encoder or stream client grow an unbounded backlog.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        outputsAttached = true
    }

    private func configureVideoConnectionLocked(rotationDegrees: Int, stabilization: StabilizationMode) {
        guard let connection = videoOutput.connection(with: .video) else { return }

        let angle = CGFloat(rotationDegrees)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        } else {
            log.notice("rotation \(rotationDegrees, privacy: .public)° not supported by this connection; leaving unrotated")
        }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = stabilization.avMode
        }

        // Front-camera buffers are not mirrored: a machine-vision client wants the
        // true sensor geometry, not a selfie view.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func resolveDevice(selector: String) throws -> AVCaptureDevice {
        let cameras = discoveredCameras()

        switch selector.lowercased() {
        case "back", "rear":
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                return device
            }
            if let device = cameras.first(where: { $0.position == .back }) { return device }
        case "front":
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                return device
            }
            if let device = cameras.first(where: { $0.position == .front }) { return device }
        default:
            if let device = cameras.first(where: { $0.uniqueID == selector }) { return device }
        }

        if cameras.isEmpty {
            throw APIError.unavailable("No camera is available on this device. (The iOS Simulator has no camera; run on hardware.)")
        }
        throw APIError.badRequest("Unknown camera '\(selector)'. Use 'back', 'front', or a uniqueID from GET /formats.")
    }

    private func discoveredCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // MARK: - Recording

    func startRecording(name requestedName: String?, container: MediaContainer, maxDurationSeconds: Double?) throws -> ActiveRecordingDTO {
        guard !isRecording else {
            throw APIError.conflict("A recording is already in progress. Call POST /record/stop first.")
        }
        guard videoDevice != nil else {
            throw APIError.unavailable("No camera configured; cannot record.")
        }
        guard session.isRunning else {
            throw APIError.unavailable("Capture session is not running. Check GET /status for the reason.")
        }
        if let maxDurationSeconds, maxDurationSeconds <= 0 {
            throw APIError.badRequest("maxDurationSeconds must be greater than zero.")
        }

        let config = configuration
        let id = UUID().uuidString
        let name = requestedName.flatMap { RecordingStore.sanitize(name: $0) } ?? id
        let url = store.mediaURL(id: id, container: container)
        try? FileManager.default.removeItem(at: url)

        // iOS 27 deprecates this writer API in favour of the async
        // `inputReceiver(for:)` / `SampleBufferReceiver` pair. We stay on the
        // synchronous path deliberately: buffers arrive on a serial dispatch
        // queue from the capture delegate, and appending them inline preserves
        // ordering and back-pressure without bridging every frame into an async
        // context. The deprecated calls remain fully functional.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: container.fileType)
        } catch {
            throw APIError.internalError("Could not create asset writer: \(error.localizedDescription)")
        }

        let width = config.encodedWidth
        let height = config.encodedHeight

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(config.fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: config.keyFrameInterval,
        ]
        if config.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: config.codec.avCodecType,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw APIError.internalError("Asset writer rejected the video input (\(width)x\(height), \(config.codec.rawValue)).")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if config.audioEnabled, audioDeviceInput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: 96_000,
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown error"
            throw APIError.internalError("Asset writer failed to start: \(reason)")
        }

        let recording = ActiveRecording(
            id: id,
            name: name,
            container: container,
            url: url,
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            configuration: config,
            encodedWidth: width,
            encodedHeight: height,
            maxDurationSeconds: maxDurationSeconds
        )

        stateLock.withLock { _recordingInterruptions = [] }

        // Hand off under `sampleQueue` so a frame in flight cannot interleave.
        // The emptiness check happens here rather than at the top of the method so
        // two concurrent /record/start calls cannot both install a writer and
        // orphan one of the files.
        let alreadyRecording: Bool = sampleQueue.sync {
            guard self.activeRecording == nil else { return true }
            self.activeRecording = recording
            return false
        }
        if alreadyRecording {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw APIError.conflict("A recording is already in progress. Call POST /record/stop first.")
        }

        let dto = ActiveRecordingDTO(
            id: id,
            name: name,
            startedAt: recording.startedAt,
            durationSeconds: 0,
            framesWritten: 0,
            framesDropped: 0,
            captureDrops: 0,
            writerBackpressureDrops: 0,
            appendFailures: 0,
            bytesWritten: 0,
            maxDurationSeconds: maxDurationSeconds,
            firstVideoPTSSeconds: nil,
            lastVideoPTSSeconds: nil,
            interruptions: []
        )
        stateLock.withLock { _progress = dto }
        onRecordingChange?(true)
        events.send(event: "recording.started", payload: EventEnvelope(type: "recording.started", timestamp: Date(), payload: dto))
        log.info("recording started: \(id, privacy: .public) \(width, privacy: .public)x\(height, privacy: .public)")

        return dto
    }

    func stopRecording(timeout: TimeInterval = 30) throws -> RecordingDTO {
        let recording: ActiveRecording? = sampleQueue.sync {
            let current = self.activeRecording
            self.activeRecording = nil
            return current
        }

        guard let recording else {
            throw APIError.conflict("No recording is in progress.")
        }

        stateLock.withLock { _progress = nil }
        onRecordingChange?(false)

        // No frames ever arrived, so there is no valid movie to finalise.
        guard recording.sessionStarted else {
            recording.writer.cancelWriting()
            try? FileManager.default.removeItem(at: recording.url)
            throw APIError.internalError("Recording stopped before any frame was captured; nothing was written.")
        }

        recording.videoInput.markAsFinished()
        recording.audioInput?.markAsFinished()
        recording.writer.endSession(atSourceTime: recording.lastPTS)

        let semaphore = DispatchSemaphore(value: 0)
        recording.writer.finishWriting { semaphore.signal() }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw APIError.internalError("Timed out after \(Int(timeout))s finalising the recording.")
        }

        guard recording.writer.status == .completed else {
            let reason = recording.writer.error?.localizedDescription ?? "status \(recording.writer.status.rawValue)"
            try? FileManager.default.removeItem(at: recording.url)
            throw APIError.internalError("Asset writer did not complete: \(reason)")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: recording.url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let dto = RecordingDTO(
            id: recording.id,
            name: recording.name,
            filename: recording.url.lastPathComponent,
            createdAt: recording.startedAt,
            durationSeconds: recording.durationSeconds,
            sizeBytes: size,
            width: recording.encodedWidth,
            height: recording.encodedHeight,
            fps: recording.configuration.fps,
            codec: recording.configuration.codec.rawValue,
            container: recording.container.rawValue,
            hasAudio: recording.audioInput != nil,
            framesWritten: recording.framesWritten,
            framesDropped: recording.framesDropped,
            cameraPosition: videoDevice?.position.name ?? "unknown",
            rotationDegrees: recording.configuration.rotationDegrees,
            timing: RecordingTimingDTO(
                firstVideoPTSSeconds: CMTimeGetSeconds(recording.firstPTS),
                lastVideoPTSSeconds: CMTimeGetSeconds(recording.lastPTS),
                captureDrops: recording.captureDrops,
                writerBackpressureDrops: recording.writerBackpressureDrops,
                appendFailures: recording.appendFailures,
                keyFrameInterval: recording.configuration.keyFrameInterval,
                interruptions: stateLock.withLock { _recordingInterruptions }
            )
        )

        store.save(dto)
        events.send(event: "recording.stopped", payload: EventEnvelope(type: "recording.stopped", timestamp: Date(), payload: dto))
        log.info("recording finished: \(dto.id, privacy: .public) \(dto.framesWritten, privacy: .public) frames, \(size, privacy: .public) bytes")

        return dto
    }

    // MARK: - Clock

    /// Reads the clock that sample buffer timestamps are expressed in.
    ///
    /// `AVCaptureSession.synchronizationClock` is the authority here — the SDK
    /// states that all capture output timestamps are on its timebase. Reading
    /// `mach_absolute_time()` directly would agree today, but would silently
    /// diverge if the session were ever driven by another clock.
    func clockReading() -> ClockResponseDTO {
        let hostClock = CMClockGetHostTimeClock()
        let captureClock = session.synchronizationClock

        // Read the two as close together as possible; their difference is
        // reported so a caller can see any skew rather than assume none.
        let captureTime = captureClock.map { CMClockGetTime($0) } ?? CMClockGetTime(hostClock)
        let hostTime = CMClockGetTime(hostClock)

        let captureSeconds = CMTimeGetSeconds(captureTime)
        let hostSeconds = CMTimeGetSeconds(hostTime)

        return ClockResponseDTO(
            captureClockSeconds: captureSeconds,
            captureClockNanos: Self.nanoseconds(captureTime),
            hostClockSeconds: hostSeconds,
            hostClockNanos: Self.nanoseconds(hostTime),
            captureMinusHostSeconds: captureSeconds - hostSeconds,
            captureClockAvailable: captureClock != nil
        )
    }

    private static func nanoseconds(_ time: CMTime) -> Int64 {
        guard time.isValid else { return 0 }
        return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    /// The capture clock alone, for stamping events.
    private func captureClockSeconds() -> Double {
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        return CMTimeGetSeconds(CMClockGetTime(clock))
    }

    // MARK: - Snapshot

    /// Blocks until the next frame arrives, then returns it as JPEG.
    func snapshot(maxWidth: Int, quality: Double, timeout: TimeInterval = 5) throws -> Data {
        guard session.isRunning else {
            throw APIError.unavailable("Capture session is not running. Check GET /status.")
        }
        let request = SnapshotRequest(maxWidth: maxWidth, quality: quality)
        sampleQueue.async { self.pendingSnapshots.append(request) }

        guard request.semaphore.wait(timeout: .now() + timeout) == .success, let data = request.data else {
            sampleQueue.async { self.pendingSnapshots.removeAll { $0 === request } }
            throw APIError.unavailable("No frame arrived within \(Int(timeout))s.")
        }
        return data
    }

    // MARK: - Controls

    /// A change whose effect lands asynchronously — the lens has to physically
    /// travel, the exposure ramp has to run.
    ///
    /// The AVFoundation call itself is always made *inside* `lockForConfiguration`
    /// (calling it unlocked throws `NSGenericException`); only the waiting happens
    /// after the lock is released, so `POST /control` can report state that has
    /// actually taken effect without pinning the device lock while it blocks.
    private enum PendingSettle {
        /// A call that reports completion through a handler.
        case handler(label: String, semaphore: DispatchSemaphore)
        /// A one-shot scan. `.autoFocus`, `.autoExpose` and `.autoWhiteBalance`
        /// have no completion handler; the only signal is the device's
        /// `isAdjusting…` flag dropping back to false.
        case scan(label: String, isAdjusting: () -> Bool)
    }

    func applyControls(_ request: ControlRequest) throws -> ControlStateDTO {
        guard let device = videoDevice else {
            throw APIError.unavailable("No camera configured.")
        }

        var pending: [PendingSettle] = []

        do {
            try device.lockForConfiguration()
        } catch {
            throw APIError.internalError("Could not lock camera: \(error.localizedDescription)")
        }

        do {
            if let focus = request.focus {
                try applyFocus(focus, to: device, pending: &pending)
            }
            if let exposure = request.exposure {
                try applyExposure(exposure, to: device, pending: &pending)
            }
            if let whiteBalance = request.whiteBalance {
                try applyWhiteBalance(whiteBalance, to: device, pending: &pending)
            }
            if let zoom = request.zoom {
                let lower = device.minAvailableVideoZoomFactor
                let upper = device.maxAvailableVideoZoomFactor
                guard zoom >= lower, zoom <= upper else {
                    throw APIError.badRequest("zoom must be between \(lower) and \(upper) for this camera and format.")
                }
                device.videoZoomFactor = CGFloat(zoom)
            }
            if let torch = request.torch {
                try applyTorch(torch, to: device)
            }
        } catch {
            device.unlockForConfiguration()
            throw error
        }

        // Every mutating call has now been made under the lock. Release it before
        // blocking: the scans take up to seconds, and the capture pipeline needs
        // the device back.
        device.unlockForConfiguration()

        for settle in pending { awaitSettle(settle) }

        return controlState()
    }

    /// Blocks until a device change lands. A timeout only logs: the hardware may
    /// legitimately still be ramping, and reporting slightly-early state beats
    /// failing a request that did take effect.
    private func awaitSettle(_ settle: PendingSettle, timeout: TimeInterval = 3.0) {
        switch settle {
        case .handler(let label, let semaphore):
            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                log.notice("\(label, privacy: .public) did not settle within \(timeout, privacy: .public)s")
            }

        case .scan(let label, let isAdjusting):
            let start = Date()
            // The scan does not raise the flag instantly, so wait briefly for it
            // to begin before watching for it to end — otherwise a fast check
            // sees "not adjusting" and returns before the sweep even starts.
            while !isAdjusting(), Date().timeIntervalSince(start) < 0.25 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            while isAdjusting(), Date().timeIntervalSince(start) < timeout {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if isAdjusting() {
                log.notice("\(label, privacy: .public) still scanning after \(timeout, privacy: .public)s")
            }
        }
    }

    private func applyFocus(
        _ focus: ControlRequest.Focus,
        to device: AVCaptureDevice,
        pending: inout [PendingSettle]
    ) throws {
        if let point = focus.pointOfInterest {
            guard point.count == 2, (0...1).contains(point[0]), (0...1).contains(point[1]) else {
                throw APIError.badRequest("focus.pointOfInterest must be [x, y] with both in 0...1.")
            }
            guard device.isFocusPointOfInterestSupported else {
                throw APIError.badRequest("This camera does not support a focus point of interest.")
            }
            device.focusPointOfInterest = CGPoint(x: point[0], y: point[1])
        }

        guard let mode = focus.mode?.lowercased() else { return }
        switch mode {
        case "auto", "continuous":
            guard device.isFocusModeSupported(.continuousAutoFocus) else {
                throw APIError.badRequest("This camera does not support continuous autofocus.")
            }
            device.focusMode = .continuousAutoFocus
        case "single", "once", "auto_once":
            // AF-S: sweep once, then AVFoundation moves the mode to .locked by
            // itself. Waiting for the sweep is what makes this useful — the caller
            // gets back a settled lens position and nothing re-focuses afterwards.
            guard device.isFocusModeSupported(.autoFocus) else {
                throw APIError.badRequest("This camera does not support single-shot autofocus.")
            }
            device.focusMode = .autoFocus
            pending.append(.scan(label: "single-shot focus", isAdjusting: { device.isAdjustingFocus }))
        case "locked":
            guard device.isFocusModeSupported(.locked) else {
                throw APIError.badRequest("This camera does not support locked focus.")
            }
            device.focusMode = .locked
        case "manual":
            guard device.isLockingFocusWithCustomLensPositionSupported else {
                throw APIError.badRequest("This camera does not support manual lens position.")
            }
            guard let position = focus.lensPosition else {
                throw APIError.badRequest("focus.lensPosition is required when focus.mode is 'manual'.")
            }
            guard (0...1).contains(position) else {
                throw APIError.badRequest("focus.lensPosition must be in 0...1 (0 = near, 1 = far); got \(position).")
            }
            let semaphore = DispatchSemaphore(value: 0)
            device.setFocusModeLocked(lensPosition: position) { _ in semaphore.signal() }
            pending.append(.handler(label: "focus lens position", semaphore: semaphore))
        default:
            throw APIError.badRequest("Unknown focus.mode '\(mode)'. Expected 'auto', 'single', 'locked' or 'manual'.")
        }
    }

    private func applyExposure(
        _ exposure: ControlRequest.Exposure,
        to device: AVCaptureDevice,
        pending: inout [PendingSettle]
    ) throws {
        if let point = exposure.pointOfInterest {
            guard point.count == 2, (0...1).contains(point[0]), (0...1).contains(point[1]) else {
                throw APIError.badRequest("exposure.pointOfInterest must be [x, y] with both in 0...1.")
            }
            guard device.isExposurePointOfInterestSupported else {
                throw APIError.badRequest("This camera does not support an exposure point of interest.")
            }
            device.exposurePointOfInterest = CGPoint(x: point[0], y: point[1])
        }

        if let bias = exposure.targetBias {
            let lower = device.minExposureTargetBias
            let upper = device.maxExposureTargetBias
            guard bias >= lower, bias <= upper else {
                throw APIError.badRequest("exposure.targetBias must be between \(lower) and \(upper).")
            }
            let semaphore = DispatchSemaphore(value: 0)
            device.setExposureTargetBias(bias) { _ in semaphore.signal() }
            pending.append(.handler(label: "exposure target bias", semaphore: semaphore))
        }

        guard let mode = exposure.mode?.lowercased() else { return }
        switch mode {
        case "auto", "continuous":
            guard device.isExposureModeSupported(.continuousAutoExposure) else {
                throw APIError.badRequest("This camera does not support continuous auto exposure.")
            }
            device.exposureMode = .continuousAutoExposure
        case "single", "once", "auto_once":
            // Meter once, then AVFoundation locks it. The exposure equivalent of AF-S.
            guard device.isExposureModeSupported(.autoExpose) else {
                throw APIError.badRequest("This camera does not support single-shot auto exposure.")
            }
            device.exposureMode = .autoExpose
            pending.append(.scan(label: "single-shot exposure", isAdjusting: { device.isAdjustingExposure }))
        case "locked":
            guard device.isExposureModeSupported(.locked) else {
                throw APIError.badRequest("This camera does not support locked exposure.")
            }
            device.exposureMode = .locked
        case "manual", "custom":
            guard device.isExposureModeSupported(.custom) else {
                throw APIError.badRequest("This camera does not support manual exposure.")
            }
            let format = device.activeFormat
            let minDuration = CMTimeGetSeconds(format.minExposureDuration)
            let maxDuration = CMTimeGetSeconds(format.maxExposureDuration)

            let duration: CMTime
            if let seconds = exposure.durationSeconds {
                guard seconds >= minDuration, seconds <= maxDuration else {
                    throw APIError.badRequest("exposure.durationSeconds must be between \(minDuration) and \(maxDuration) for the active format.")
                }
                duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            } else {
                duration = AVCaptureDevice.currentExposureDuration
            }

            let iso: Float
            if let requested = exposure.iso {
                guard requested >= format.minISO, requested <= format.maxISO else {
                    throw APIError.badRequest("exposure.iso must be between \(format.minISO) and \(format.maxISO) for the active format.")
                }
                iso = requested
            } else {
                iso = AVCaptureDevice.currentISO
            }

            let semaphore = DispatchSemaphore(value: 0)
            device.setExposureModeCustom(duration: duration, iso: iso) { _ in semaphore.signal() }
            pending.append(.handler(label: "custom exposure", semaphore: semaphore))
        default:
            throw APIError.badRequest("Unknown exposure.mode '\(mode)'. Expected 'auto', 'single', 'locked' or 'manual'.")
        }
    }

    private func applyWhiteBalance(
        _ whiteBalance: ControlRequest.WhiteBalance,
        to device: AVCaptureDevice,
        pending: inout [PendingSettle]
    ) throws {
        guard let mode = whiteBalance.mode?.lowercased() else { return }
        switch mode {
        case "auto", "continuous":
            guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
                throw APIError.badRequest("This camera does not support continuous auto white balance.")
            }
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        case "single", "once", "auto_once":
            guard device.isWhiteBalanceModeSupported(.autoWhiteBalance) else {
                throw APIError.badRequest("This camera does not support single-shot auto white balance.")
            }
            device.whiteBalanceMode = .autoWhiteBalance
            pending.append(.scan(label: "single-shot white balance", isAdjusting: { device.isAdjustingWhiteBalance }))
        case "locked":
            guard device.isWhiteBalanceModeSupported(.locked) else {
                throw APIError.badRequest("This camera does not support locked white balance.")
            }
            device.whiteBalanceMode = .locked
        case "manual":
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                throw APIError.badRequest("This camera does not support manual white balance gains.")
            }
            let current = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: whiteBalance.temperature ?? current.temperature,
                tint: whiteBalance.tint ?? current.tint
            )
            var gains = device.deviceWhiteBalanceGains(for: values)
            // Out-of-gamut temperature/tint pairs produce gains the hardware rejects.
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1.0), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
            let semaphore = DispatchSemaphore(value: 0)
            device.setWhiteBalanceModeLocked(with: gains) { _ in semaphore.signal() }
            pending.append(.handler(label: "white balance gains", semaphore: semaphore))
        default:
            throw APIError.badRequest("Unknown whiteBalance.mode '\(mode)'. Expected 'auto', 'single', 'locked' or 'manual'.")
        }
    }

    private func applyTorch(_ torch: ControlRequest.Torch, to device: AVCaptureDevice) throws {
        guard device.hasTorch else {
            throw APIError.badRequest("This camera has no torch.")
        }
        if let level = torch.level {
            guard (0...1).contains(level) else {
                throw APIError.badRequest("torch.level must be in 0...1.")
            }
            if torch.on ?? true {
                do {
                    try device.setTorchModeOn(level: max(level, 0.01))
                } catch {
                    throw APIError.internalError("Could not set torch level: \(error.localizedDescription)")
                }
                return
            }
        }
        if let on = torch.on {
            device.torchMode = on ? .on : .off
        }
    }

    func controlState() -> ControlStateDTO {
        guard let device = videoDevice else {
            return ControlStateDTO(
                focusMode: "unavailable", lensPosition: 0,
                exposureMode: "unavailable", exposureDurationSeconds: 0, iso: 0, exposureTargetBias: 0,
                whiteBalanceMode: "unavailable", temperature: 0, tint: 0,
                zoom: 1, torchOn: false, torchLevel: 0
            )
        }
        let temperatureAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        return ControlStateDTO(
            focusMode: Self.name(for: device.focusMode),
            lensPosition: device.lensPosition,
            exposureMode: Self.name(for: device.exposureMode),
            exposureDurationSeconds: CMTimeGetSeconds(device.exposureDuration),
            iso: device.iso,
            exposureTargetBias: device.exposureTargetBias,
            whiteBalanceMode: Self.name(for: device.whiteBalanceMode),
            temperature: temperatureAndTint.temperature,
            tint: temperatureAndTint.tint,
            zoom: Double(device.videoZoomFactor),
            torchOn: device.hasTorch && device.torchMode == .on,
            torchLevel: device.hasTorch ? device.torchLevel : 0
        )
    }

    // MARK: - Introspection

    func cameraDescriptors() -> [CameraDescriptorDTO] {
        let active = videoDevice?.uniqueID
        return discoveredCameras().map { device in
            CameraDescriptorDTO(
                uniqueID: device.uniqueID,
                localizedName: device.localizedName,
                position: device.position.name,
                deviceType: device.deviceType.rawValue,
                isActive: device.uniqueID == active,
                minZoom: Double(device.minAvailableVideoZoomFactor),
                maxZoom: Double(device.maxAvailableVideoZoomFactor),
                hasTorch: device.hasTorch
            )
        }
    }

    func formats(cameraSelector: String?) throws -> FormatsResponseDTO {
        let device: AVCaptureDevice
        if let cameraSelector {
            device = try resolveDevice(selector: cameraSelector)
        } else if let current = videoDevice {
            device = current
        } else {
            device = try resolveDevice(selector: configuration.cameraSelector)
        }

        let activeFormat = device.activeFormat
        let formats = device.formats.enumerated().map { index, format -> FormatDescriptorDTO in
            let dimensions = format.dimensions
            let ranges = format.videoSupportedFrameRateRanges
            return FormatDescriptorDTO(
                index: index,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                minFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                maxFrameRate: ranges.map(\.maxFrameRate).max() ?? 0,
                pixelFormat: format.pixelFormatName,
                isBinned: format.isVideoBinned,
                fieldOfView: Double(format.videoFieldOfView),
                maxZoomFactor: Double(format.videoMaxZoomFactor),
                supportsVideoStabilization: format.isVideoStabilizationModeSupported(.standard),
                isActive: format == activeFormat
            )
        }

        let descriptors = cameraDescriptors()
        let selfDescriptor = descriptors.first { $0.uniqueID == device.uniqueID }
            ?? CameraDescriptorDTO(
                uniqueID: device.uniqueID,
                localizedName: device.localizedName,
                position: device.position.name,
                deviceType: device.deviceType.rawValue,
                isActive: false,
                minZoom: Double(device.minAvailableVideoZoomFactor),
                maxZoom: Double(device.maxAvailableVideoZoomFactor),
                hasTorch: device.hasTorch
            )

        return FormatsResponseDTO(camera: selfDescriptor, cameras: descriptors, formats: formats)
    }

    func sessionState() -> SessionStateDTO {
        let (config, formatIndex, lastError, interrupted, reason) = stateLock.withLock {
            (_configuration, _activeFormatIndex, _lastError, _interrupted, _interruptionReason)
        }

        return SessionStateDTO(
            running: session.isRunning,
            interrupted: interrupted,
            interruptionReason: reason,
            cameraPermission: Self.permissionStatusName(for: .video),
            microphonePermission: Self.permissionStatusName(for: .audio),
            config: SessionConfigDTO(
                camera: videoDevice?.uniqueID ?? config.cameraSelector,
                cameraPosition: videoDevice?.position.name ?? "unknown",
                width: config.width,
                height: config.height,
                fps: config.fps,
                codec: config.codec.rawValue,
                bitrate: config.bitrate,
                audioEnabled: config.audioEnabled && audioDeviceInput != nil,
                rotationDegrees: config.rotationDegrees,
                stabilization: config.stabilization.rawValue,
                formatIndex: formatIndex,
                keyFrameInterval: config.keyFrameInterval
            ),
            lastError: lastError
        )
    }

    private func setLastError(_ message: String?) {
        stateLock.withLock { _lastError = message }
        if let message {
            events.send(event: "error", payload: EventEnvelope(type: "error", timestamp: Date(), payload: MessagePayload(message: message)))
        }
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = Self.interruptionReasonName(raw)
            let onset = Date()
            let clock = self.captureClockSeconds()
            self.stateLock.withLock {
                self._interrupted = true
                self._interruptionReason = reason
                // Only log against a live recording; an interruption while idle
                // says nothing about any episode's footage.
                if self._progress != nil {
                    self._recordingInterruptions.append(InterruptionDTO(
                        reason: reason,
                        startedAt: onset,
                        endedAt: nil,
                        captureClockSeconds: clock,
                        durationSeconds: nil
                    ))
                }
            }
            self.log.notice("session interrupted: \(reason, privacy: .public)")
            self.events.send(
                event: "session.interrupted",
                payload: EventEnvelope(type: "session.interrupted", timestamp: Date(), payload: MessagePayload(message: reason))
            )
        }

        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            let ended = Date()
            self.stateLock.withLock {
                self._interrupted = false
                self._interruptionReason = nil
                // Close the most recent open entry, if this recording saw one.
                if let index = self._recordingInterruptions.lastIndex(where: { $0.endedAt == nil }) {
                    let open = self._recordingInterruptions[index]
                    self._recordingInterruptions[index] = InterruptionDTO(
                        reason: open.reason,
                        startedAt: open.startedAt,
                        endedAt: ended,
                        captureClockSeconds: open.captureClockSeconds,
                        durationSeconds: ended.timeIntervalSince(open.startedAt)
                    )
                }
            }
            self.log.notice("session interruption ended")
            self.events.send(
                event: "session.resumed",
                payload: EventEnvelope(type: "session.resumed", timestamp: Date(), payload: EmptyPayload())
            )
        }

        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "unknown runtime error"
            self.setLastError(message)
            self.log.error("runtime error: \(message, privacy: .public)")
            // Media-services resets are recoverable by simply restarting.
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    private static func interruptionReasonName(_ raw: Int?) -> String {
        guard let raw, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "unknown"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "video_device_not_available_in_background"
        case .audioDeviceInUseByAnotherClient:
            return "audio_device_in_use_by_another_client"
        case .videoDeviceInUseByAnotherClient:
            return "video_device_in_use_by_another_client"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "video_device_not_available_with_multiple_foreground_apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "video_device_not_available_due_to_system_pressure"
        case .sensitiveContentMitigationActivated:
            return "sensitive_content_mitigation_activated"
        @unknown default:
            return "unknown"
        }
    }

    private static func name(for mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoFocus: return "auto_once"
        case .continuousAutoFocus: return "auto"
        @unknown default: return "unknown"
        }
    }

    private static func name(for mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoExpose: return "auto_once"
        case .continuousAutoExposure: return "auto"
        case .custom: return "manual"
        @unknown default: return "unknown"
        }
    }

    private static func name(for mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoWhiteBalance: return "auto_once"
        case .continuousAutoWhiteBalance: return "auto"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Sample buffer delivery

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Both delegates share `sampleQueue`, so this is always serialised.
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else {
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoOutput, let recording = activeRecording else { return }
        recording.captureDrops += 1
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let recording = activeRecording {
            appendVideo(sampleBuffer, presentationTime: presentationTime, to: recording)
            if let limit = recording.maxDurationSeconds, recording.durationSeconds >= limit {
                autoStop(reason: "max_duration_reached")
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        servicePendingSnapshots(pixelBuffer)
        serviceStream(pixelBuffer)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime, to recording: ActiveRecording) {
        if !recording.sessionStarted {
            guard presentationTime.isValid else { return }
            recording.writer.startSession(atSourceTime: presentationTime)
            recording.firstPTS = presentationTime
            recording.lastPTS = presentationTime
            recording.sessionStarted = true

            // `recording.started` fires when the HTTP request is handled, before
            // any frame exists. This is the event that carries the timing anchor.
            if !recording.firstFrameAnnounced {
                recording.firstFrameAnnounced = true
                let dto = self.progressDTO(for: recording, bytesWritten: 0)
                self.events.send(
                    event: "recording.firstFrame",
                    payload: EventEnvelope(type: "recording.firstFrame", timestamp: Date(), payload: dto)
                )
            }
        }

        guard recording.writer.status == .writing else {
            if recording.writer.status == .failed {
                let message = recording.writer.error?.localizedDescription ?? "asset writer failed"
                setLastError(message)
            }
            return
        }

        guard recording.videoInput.isReadyForMoreMediaData else {
            recording.writerBackpressureDrops += 1
            return
        }

        if recording.videoInput.append(sampleBuffer) {
            recording.framesWritten += 1
            recording.lastPTS = presentationTime
            // Publishing costs a stat(), so it is paced by wall clock rather than
            // frame count — at 240 fps a per-N-frames rule would fire 8x a second.
            let now = CACurrentMediaTime()
            if now - lastProgressPublish >= 0.5 {
                lastProgressPublish = now
                publishProgress(for: recording)
            }
        } else {
            recording.appendFailures += 1
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let recording = activeRecording,
              let audioInput = recording.audioInput,
              // Audio before the first video frame would extend the timeline backwards.
              recording.sessionStarted,
              recording.writer.status == .writing,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        _ = audioInput.append(sampleBuffer)
    }

    /// Builds the in-flight snapshot. `bytesWritten` is passed in because
    /// stat()-ing the file is the expensive part and not every caller needs it.
    private func progressDTO(for recording: ActiveRecording, bytesWritten: Int64) -> ActiveRecordingDTO {
        ActiveRecordingDTO(
            id: recording.id,
            name: recording.name,
            startedAt: recording.startedAt,
            durationSeconds: recording.durationSeconds,
            framesWritten: recording.framesWritten,
            framesDropped: recording.framesDropped,
            captureDrops: recording.captureDrops,
            writerBackpressureDrops: recording.writerBackpressureDrops,
            appendFailures: recording.appendFailures,
            bytesWritten: bytesWritten,
            maxDurationSeconds: recording.maxDurationSeconds,
            firstVideoPTSSeconds: recording.firstPTS.isValid ? CMTimeGetSeconds(recording.firstPTS) : nil,
            lastVideoPTSSeconds: recording.lastPTS.isValid ? CMTimeGetSeconds(recording.lastPTS) : nil,
            interruptions: stateLock.withLock { _recordingInterruptions }
        )
    }

    private func publishProgress(for recording: ActiveRecording) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: recording.url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let dto = progressDTO(for: recording, bytesWritten: size)
        stateLock.withLock { _progress = dto }
    }

    private func autoStop(reason: String) {
        // Stopping blocks on `finishWriting`, which must not happen on `sampleQueue`.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.stopRecording()
                self.events.send(
                    event: "recording.autostopped",
                    payload: EventEnvelope(type: "recording.autostopped", timestamp: Date(), payload: MessagePayload(message: reason))
                )
            } catch {
                self.log.error("auto-stop failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func servicePendingSnapshots(_ pixelBuffer: CVPixelBuffer) {
        guard !pendingSnapshots.isEmpty else { return }
        let requests = pendingSnapshots
        pendingSnapshots.removeAll()
        for request in requests {
            request.data = jpegEncoder.encode(
                pixelBuffer: pixelBuffer,
                maxWidth: request.maxWidth,
                quality: request.quality
            )
            request.semaphore.signal()
        }
    }

    private func serviceStream(_ pixelBuffer: CVPixelBuffer) {
        guard mjpeg.hasSubscribers else { return }

        let settings = streamSettings
        let now = CACurrentMediaTime()
        let interval = 1.0 / settings.fps
        guard now - lastStreamedFrameTime >= interval else { return }
        lastStreamedFrameTime = now

        guard let jpeg = jpegEncoder.encode(
            pixelBuffer: pixelBuffer,
            maxWidth: settings.maxWidth,
            quality: settings.quality
        ) else { return }

        mjpeg.send(jpeg: jpeg)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
