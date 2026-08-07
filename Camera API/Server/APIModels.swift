import Foundation

// MARK: - Requests

/// Reconfigures the capture session. Every field is optional; omitted fields keep
/// their current value.
struct ConfigureRequest: Decodable {
    /// `"back"`, `"front"`, or a `uniqueID` from `GET /formats`.
    var camera: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    /// `"h264"` or `"hevc"`.
    var codec: String?
    var bitrate: Int?
    var audio: Bool?
    /// 0, 90, 180 or 270. Applied to the buffers themselves, so recordings and the
    /// MJPEG stream come out identically oriented.
    var rotationDegrees: Int?
    /// `"off"`, `"standard"`, `"cinematic"`, `"cinematicExtended"` or `"auto"`.
    var stabilization: String?
    /// Bypasses resolution/fps matching and selects `formats[index]` directly.
    var formatIndex: Int?
    /// Frames between keyframes. Defaults to `2 x fps`, which is fine for
    /// playback but expensive for random access — a seek must decode up to a
    /// whole interval. Training pipelines that sample random subsequences want
    /// something small (10-15), or 1 for all-intra.
    var keyFrameInterval: Int?
}

struct ControlRequest: Decodable {
    struct Focus: Decodable {
        /// `"auto"` (continuous), `"locked"`, or `"manual"`.
        var mode: String?
        /// 0.0 (near) to 1.0 (far). Requires `mode: "manual"`.
        var lensPosition: Float?
        /// Normalised {x, y} in 0...1, origin top-left in the sensor's landscape space.
        var pointOfInterest: [Double]?
    }

    struct Exposure: Decodable {
        /// `"auto"` (continuous), `"locked"`, or `"manual"`.
        var mode: String?
        /// Shutter time in seconds. Requires `mode: "manual"`.
        var durationSeconds: Double?
        /// Requires `mode: "manual"`.
        var iso: Float?
        /// EV bias applied in auto mode.
        var targetBias: Float?
        var pointOfInterest: [Double]?
    }

    struct WhiteBalance: Decodable {
        /// `"auto"` (continuous), `"locked"`, or `"manual"`.
        var mode: String?
        /// Kelvin. Requires `mode: "manual"`.
        var temperature: Float?
        /// -150...150. Requires `mode: "manual"`.
        var tint: Float?
    }

    struct Torch: Decodable {
        var on: Bool?
        /// 0.0...1.0
        var level: Float?
    }

    var focus: Focus?
    var exposure: Exposure?
    var whiteBalance: WhiteBalance?
    var zoom: Double?
    var torch: Torch?
}

struct RecordStartRequest: Decodable {
    /// Optional client-supplied name. Sanitised; a UUID is used when absent.
    var name: String?
    /// `"mov"` or `"mp4"`. Defaults to `"mov"`.
    var container: String?
    /// Stops automatically after this many seconds. Useful for unattended capture.
    var maxDurationSeconds: Double?
}

struct StreamSettingsRequest: Decodable {
    /// Frames per second pushed to MJPEG clients, independent of capture fps.
    var fps: Double?
    /// JPEG quality, 0.0...1.0.
    var quality: Double?
    /// Longest edge of streamed frames; frames are downscaled to fit.
    var maxWidth: Int?
}

struct ServerSettingsRequest: Decodable {
    var port: Int?
    /// `"usb_only"` or `"network"`.
    var accessMode: String?
    /// Send `""` to clear.
    var authToken: String?
}

// MARK: - Responses

/// Encodes `nil` as an explicit JSON `null` rather than dropping the key.
///
/// Swift's synthesised `Encodable` uses `encodeIfPresent` for optional
/// properties, so a nil field vanishes from the payload entirely. For a
/// machine-facing API a stable key set is worth far more than the handful of
/// bytes saved: a client can write `status["recording"]` without first checking
/// whether the key exists. Response DTOs wrap their optionals in this.
@propertyWrapper
struct Nullable<Wrapped: Encodable>: Encodable {
    var wrappedValue: Wrapped?

    init(wrappedValue: Wrapped?) {
        self.wrappedValue = wrappedValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension Nullable: Decodable where Wrapped: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Wrapped.self)
    }
}

// MARK: - Clock

/// A reading of the phone's clocks, for aligning video timestamps with an
/// external timeline (robot telemetry, another sensor, a second device).
///
/// Correlate against `captureClockSeconds`: it is the timebase every sample
/// buffer presentation timestamp is expressed in, and the domain that
/// `firstVideoPTSSeconds` lives in.
struct ClockResponseDTO: Encodable {
    /// `AVCaptureSession.synchronizationClock` — the PTS timebase.
    let captureClockSeconds: Double
    let captureClockNanos: Int64
    /// The system host clock (`mach_absolute_time`) read at the same instant.
    let hostClockSeconds: Double
    let hostClockNanos: Int64
    /// `captureClock - hostClock`. Zero when the capture session is driven by
    /// the host clock, which is the normal case. A non-zero value means sample
    /// timestamps are on a different timebase and only `captureClock` is valid
    /// for correlating with PTS.
    let captureMinusHostSeconds: Double
    /// False when no session is running, in which case `captureClock` falls
    /// back to the host clock.
    let captureClockAvailable: Bool
}

/// A capture interruption that overlapped a recording. Any entry here means the
/// footage has a gap and the episode should be treated as suspect.
struct InterruptionDTO: Codable {
    let reason: String
    let startedAt: Date
    @Nullable var endedAt: Date?
    /// Onset on the capture clock, so it can be placed against video PTS.
    let captureClockSeconds: Double
    @Nullable var durationSeconds: Double?
}

struct APIInfoDTO: Encodable {
    let name: String
    let version: String
    let uptimeSeconds: Double
    let port: Int
    let accessMode: String
    let authRequired: Bool
    let httpConnections: Int
    let mjpegClients: Int
    let eventClients: Int
}

struct DeviceInfoDTO: Encodable {
    let name: String
    let model: String
    let systemName: String
    let systemVersion: String
    let thermalState: String
    @Nullable var batteryLevel: Double?
    let batteryState: String
    let lowPowerModeEnabled: Bool
    @Nullable var freeDiskBytes: Int64?
}

struct CameraDescriptorDTO: Encodable {
    let uniqueID: String
    let localizedName: String
    let position: String
    let deviceType: String
    let isActive: Bool
    let minZoom: Double
    let maxZoom: Double
    let hasTorch: Bool
}

struct FormatDescriptorDTO: Encodable {
    let index: Int
    let width: Int
    let height: Int
    let minFrameRate: Double
    let maxFrameRate: Double
    let pixelFormat: String
    let isBinned: Bool
    let fieldOfView: Double
    let maxZoomFactor: Double
    let supportsVideoStabilization: Bool
    let isActive: Bool
}

struct FormatsResponseDTO: Encodable {
    let camera: CameraDescriptorDTO
    let cameras: [CameraDescriptorDTO]
    let formats: [FormatDescriptorDTO]
}

struct SessionConfigDTO: Encodable {
    let camera: String
    let cameraPosition: String
    let width: Int
    let height: Int
    let fps: Double
    let codec: String
    let bitrate: Int
    let audioEnabled: Bool
    let rotationDegrees: Int
    let stabilization: String
    let formatIndex: Int
    let keyFrameInterval: Int
}

struct SessionStateDTO: Encodable {
    let running: Bool
    let interrupted: Bool
    @Nullable var interruptionReason: String?
    let cameraPermission: String
    let microphonePermission: String
    let config: SessionConfigDTO
    @Nullable var lastError: String?
}

struct ControlStateDTO: Encodable {
    let focusMode: String
    let lensPosition: Float
    let exposureMode: String
    let exposureDurationSeconds: Double
    let iso: Float
    let exposureTargetBias: Float
    let whiteBalanceMode: String
    let temperature: Float
    let tint: Float
    let zoom: Double
    let torchOn: Bool
    let torchLevel: Float
}

struct ActiveRecordingDTO: Encodable {
    let id: String
    let name: String
    /// Wall clock when the *request* was handled — not when the first frame
    /// arrived. Use `firstVideoPTSSeconds` for anything timing-critical.
    let startedAt: Date
    let durationSeconds: Double
    let framesWritten: Int
    /// Total of the three specific counters below.
    let framesDropped: Int
    /// Frames the capture pipeline discarded before the writer ever saw them —
    /// the encoder or the sample queue could not keep up.
    let captureDrops: Int
    /// Frames skipped because the asset writer input was not ready to accept
    /// more data.
    let writerBackpressureDrops: Int
    /// Frames the writer rejected outright.
    let appendFailures: Int
    let bytesWritten: Int64
    @Nullable var maxDurationSeconds: Double?
    /// Presentation timestamp of the first written frame, on the capture clock
    /// (the same domain as `GET /clock`'s `captureClockSeconds`). Null until the
    /// first frame lands — watch for the `recording.firstFrame` event.
    @Nullable var firstVideoPTSSeconds: Double?
    @Nullable var lastVideoPTSSeconds: Double?
    let interruptions: [InterruptionDTO]
}

struct StreamStateDTO: Encodable {
    let fps: Double
    let quality: Double
    let maxWidth: Int
    let clients: Int
}

struct StorageDTO: Encodable {
    let recordingCount: Int
    let totalBytes: Int64
    @Nullable var freeDiskBytes: Int64?
}

struct StatusResponseDTO: Encodable {
    let api: APIInfoDTO
    let device: DeviceInfoDTO
    let session: SessionStateDTO
    let controls: ControlStateDTO
    @Nullable var recording: ActiveRecordingDTO?
    let stream: StreamStateDTO
    let storage: StorageDTO
}

/// Everything needed to place a finished recording on an external timeline,
/// plus the evidence needed to judge whether it is trustworthy.
struct RecordingTimingDTO: Codable {
    /// Presentation timestamp of the first written frame, on the capture clock
    /// — the same domain as `GET /clock`'s `captureClockSeconds`.
    ///
    /// This is the anchor, and it cannot be recovered from the file: the
    /// written movie always restarts its timeline at zero. Absolute capture
    /// time for frame *i* is `firstVideoPTSSeconds + file_pts[i]`.
    let firstVideoPTSSeconds: Double
    let lastVideoPTSSeconds: Double
    /// Frames the capture pipeline discarded before the writer saw them.
    let captureDrops: Int
    /// Frames skipped because the writer input was not ready.
    let writerBackpressureDrops: Int
    /// Frames the writer rejected outright.
    let appendFailures: Int
    /// Frames between keyframes, as requested at record time. Governs how much
    /// decoding a random-access seek costs.
    let keyFrameInterval: Int
    /// Non-empty means the capture was interrupted mid-recording and the
    /// footage has a gap.
    let interruptions: [InterruptionDTO]
}

/// One finished recording on disk.
struct RecordingDTO: Encodable, Decodable {
    let id: String
    let name: String
    let filename: String
    let createdAt: Date
    let durationSeconds: Double
    let sizeBytes: Int64
    let width: Int
    let height: Int
    let fps: Double
    let codec: String
    let container: String
    let hasAudio: Bool
    let framesWritten: Int
    let framesDropped: Int
    let cameraPosition: String
    let rotationDegrees: Int
    /// Null for recordings made before timing metadata existed.
    @Nullable var timing: RecordingTimingDTO?

    /// Relative URL the client can GET to fetch the media.
    var downloadPath: String { "/files/\(id)/download" }

    enum CodingKeys: String, CodingKey {
        case id, name, filename, createdAt, durationSeconds, sizeBytes
        case width, height, fps, codec, container, hasAudio
        case framesWritten, framesDropped, cameraPosition, rotationDegrees
        case timing
        case downloadPath
    }

    init(
        id: String, name: String, filename: String, createdAt: Date,
        durationSeconds: Double, sizeBytes: Int64, width: Int, height: Int,
        fps: Double, codec: String, container: String, hasAudio: Bool,
        framesWritten: Int, framesDropped: Int, cameraPosition: String, rotationDegrees: Int,
        timing: RecordingTimingDTO? = nil
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.container = container
        self.hasAudio = hasAudio
        self.framesWritten = framesWritten
        self.framesDropped = framesDropped
        self.cameraPosition = cameraPosition
        self.rotationDegrees = rotationDegrees
        self.timing = timing
    }

    /// `downloadPath` is derived, so it is written on encode and ignored on decode.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        filename = try values.decode(String.self, forKey: .filename)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        fps = try values.decode(Double.self, forKey: .fps)
        codec = try values.decode(String.self, forKey: .codec)
        container = try values.decode(String.self, forKey: .container)
        hasAudio = try values.decode(Bool.self, forKey: .hasAudio)
        framesWritten = try values.decode(Int.self, forKey: .framesWritten)
        framesDropped = try values.decode(Int.self, forKey: .framesDropped)
        cameraPosition = try values.decode(String.self, forKey: .cameraPosition)
        rotationDegrees = try values.decode(Int.self, forKey: .rotationDegrees)
        timing = try values.decodeIfPresent(RecordingTimingDTO.self, forKey: .timing)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(filename, forKey: .filename)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(fps, forKey: .fps)
        try container.encode(codec, forKey: .codec)
        try container.encode(self.container, forKey: .container)
        try container.encode(hasAudio, forKey: .hasAudio)
        try container.encode(framesWritten, forKey: .framesWritten)
        try container.encode(framesDropped, forKey: .framesDropped)
        try container.encode(cameraPosition, forKey: .cameraPosition)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(_timing, forKey: .timing)
        try container.encode(downloadPath, forKey: .downloadPath)
    }
}

struct RecordingListDTO: Encodable {
    let recordings: [RecordingDTO]
    let totalBytes: Int64
    @Nullable var freeDiskBytes: Int64?
}

struct DeleteResultDTO: Encodable {
    let deleted: [String]
    let freedBytes: Int64
}

struct AcknowledgementDTO: Encodable {
    let ok: Bool
    @Nullable var message: String?
}

// MARK: - Events

struct EventEnvelope<Payload: Encodable>: Encodable {
    let type: String
    let timestamp: Date
    let payload: Payload
}

struct EmptyPayload: Encodable {}

struct MessagePayload: Encodable {
    let message: String
}
