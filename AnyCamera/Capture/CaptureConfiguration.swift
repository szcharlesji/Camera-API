import AVFoundation
import Foundation

enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// Bits per pixel per frame used when the client does not pin a bitrate.
    var bitsPerPixel: Double {
        switch self {
        case .h264: return 0.10
        case .hevc: return 0.07
        }
    }

    static func parse(_ raw: String) throws -> VideoCodec {
        guard let codec = VideoCodec(rawValue: raw.lowercased()) else {
            throw APIError.badRequest("Unknown codec '\(raw)'. Expected one of: \(allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return codec
    }
}

enum StabilizationMode: String, Codable, CaseIterable, Sendable {
    case off
    case standard
    case cinematic
    case cinematicExtended
    case auto

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .cinematicExtended: return .cinematicExtended
        case .auto: return .auto
        }
    }

    static func parse(_ raw: String) throws -> StabilizationMode {
        guard let mode = StabilizationMode(rawValue: raw) else {
            throw APIError.badRequest("Unknown stabilization '\(raw)'. Expected one of: \(allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return mode
    }
}

enum MediaContainer: String, Codable, CaseIterable, Sendable {
    case mov
    case mp4

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    var mimeType: String {
        switch self {
        case .mov: return "video/quicktime"
        case .mp4: return "video/mp4"
        }
    }

    static func parse(_ raw: String) throws -> MediaContainer {
        guard let container = MediaContainer(rawValue: raw.lowercased()) else {
            throw APIError.badRequest("Unknown container '\(raw)'. Expected 'mov' or 'mp4'.")
        }
        return container
    }
}

/// The desired capture setup. Applied wholesale by `CaptureController.configure`.
struct CaptureConfiguration: Sendable, Equatable {
    /// `"back"`, `"front"`, or an `AVCaptureDevice.uniqueID`.
    var cameraSelector: String = "back"
    var width: Int = 1280
    var height: Int = 720
    var fps: Double = 60
    var codec: VideoCodec = .h264
    /// `nil` means "derive from resolution and frame rate".
    var explicitBitrate: Int?
    var audioEnabled: Bool = true
    var rotationDegrees: Int = 0
    var stabilization: StabilizationMode = .off
    /// When set, overrides resolution/fps matching and selects a format by index.
    var formatIndex: Int?
    /// Frames between keyframes. `nil` means "2 x fps".
    var explicitKeyFrameInterval: Int?
    /// Whether the encoder may emit B-frames. Turning this off makes decode
    /// order match presentation order, which keeps packet timestamps monotonic
    /// and makes frame-indexed access simpler, at some cost in compression.
    var allowFrameReordering: Bool = true

    /// Governs how much decoding a random-access seek costs: a seek lands on the
    /// preceding keyframe and decodes forward from there. The 2-second default
    /// suits playback; sampling random subsequences for training wants far less.
    var keyFrameInterval: Int {
        if let explicitKeyFrameInterval { return explicitKeyFrameInterval }
        return max(1, Int(fps.rounded()) * 2)
    }

    var bitrate: Int {
        if let explicitBitrate { return explicitBitrate }
        let raw = Double(width * height) * fps * codec.bitsPerPixel
        return Int(min(max(raw, 1_000_000), 60_000_000))
    }

    /// Buffers are rotated by the capture connection, so a quarter turn swaps the
    /// dimensions that reach the encoder.
    var isQuarterTurned: Bool {
        rotationDegrees == 90 || rotationDegrees == 270
    }

    var encodedWidth: Int { isQuarterTurned ? height : width }
    var encodedHeight: Int { isQuarterTurned ? width : height }

    static func validateRotation(_ degrees: Int) throws -> Int {
        guard [0, 90, 180, 270].contains(degrees) else {
            throw APIError.badRequest("rotationDegrees must be 0, 90, 180 or 270.")
        }
        return degrees
    }
}

/// Settings for the live MJPEG preview, independent of what gets recorded.
struct StreamSettings: Sendable, Equatable {
    var fps: Double = 15
    var quality: Double = 0.6
    var maxWidth: Int = 640

    mutating func clamp() {
        fps = min(max(fps, 1), 60)
        quality = min(max(quality, 0.1), 1.0)
        maxWidth = min(max(maxWidth, 64), 3840)
    }
}

// MARK: - Format matching

enum FormatSelector {
    /// Picks the `AVCaptureDevice.Format` that best serves the requested
    /// resolution and frame rate.
    ///
    /// Frame rate is treated as a hard requirement — asking for 60 fps and
    /// silently getting a 30 fps format would be worse than a clear error — while
    /// resolution is matched on closest total pixel distance. Among equally good
    /// matches the format with the lowest sufficient max frame rate wins, since
    /// very high speed formats tend to trade away field of view and low-light
    /// performance.
    static func bestMatch(
        formats: [AVCaptureDevice.Format],
        width: Int,
        height: Int,
        fps: Double
    ) -> AVCaptureDevice.Format? {
        // A tiny tolerance absorbs the 29.97-style rates AVFoundation reports.
        let tolerance = 0.01

        let candidates = formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                fps >= range.minFrameRate - tolerance && fps <= range.maxFrameRate + tolerance
            }
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)

            let lhsDistance = abs(Int(lhsDims.width) - width) + abs(Int(lhsDims.height) - height)
            let rhsDistance = abs(Int(rhsDims.width) - width) + abs(Int(rhsDims.height) - height)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsMax = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsMax = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lhsMax < rhsMax
        }
    }

    /// Highest frame rate any format on the device can sustain, for error messages.
    static func maxFrameRate(formats: [AVCaptureDevice.Format]) -> Double {
        formats.flatMap(\.videoSupportedFrameRateRanges).map(\.maxFrameRate).max() ?? 0
    }
}

extension AVCaptureDevice.Format {
    var dimensions: CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(formatDescription)
    }

    var pixelFormatName: String {
        let code = CMFormatDescriptionGetMediaSubType(formatDescription)
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}

extension AVCaptureDevice.Position {
    var name: String {
        switch self {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}
