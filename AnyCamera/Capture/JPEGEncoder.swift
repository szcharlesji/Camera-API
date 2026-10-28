import CoreImage
import CoreVideo
import Foundation

/// Turns capture buffers into JPEG data for the MJPEG stream and `/snapshot`.
///
/// One `CIContext` is reused for the lifetime of the app; creating one per frame
/// would rebuild the Metal pipeline every time and dominate the cost.
final class JPEGEncoder: @unchecked Sendable {
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .name: "anycamera.jpeg",
        ])
    }

    /// - Parameters:
    ///   - maxWidth: frames wider than this are scaled down to fit; taller-than-wide
    ///     frames are measured on their longest edge so a rotated stream stays bounded.
    ///   - quality: 0.0...1.0
    ///   - crop: region to keep, normalised to 0...1 with a top-left origin; applied
    ///     before scaling, so `maxWidth` bounds the cropped region.
    func encode(pixelBuffer: CVPixelBuffer, maxWidth: Int, quality: Double, crop: CGRect? = nil) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        var extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        if let crop {
            // Core Image's origin is bottom-left; the API's is top-left.
            let region = CGRect(
                x: extent.minX + crop.minX * extent.width,
                y: extent.minY + (1 - crop.maxY) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral.intersection(extent)
            guard region.width > 0, region.height > 0 else { return nil }
            image = image.cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            extent = image.extent
        }

        let longestEdge = max(extent.width, extent.height)
        if longestEdge > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / longestEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]

        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: options
        )
    }
}
