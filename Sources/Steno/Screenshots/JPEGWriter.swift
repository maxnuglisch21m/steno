import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Turns a captured frame into a JPEG file. Specification §4.7: `CGImageDestination`,
/// quality 0.8 by default, and nothing else — no cropping, no annotation, no OCR.
enum JPEGWriter {
    enum Failure: LocalizedError {
        case noDestination(URL)
        case encodingFailed(URL)
        case noImage

        var errorDescription: String? {
            switch self {
            case .noDestination(let url):
                return "could not create a JPEG destination at \(url.lastPathComponent)"
            case .encodingFailed(let url):
                return "could not finalize \(url.lastPathComponent)"
            case .noImage:
                return "the captured frame could not be turned into an image"
            }
        }
    }

    /// The quality actually used, kept inside what ImageIO accepts.
    static func clampedQuality(_ quality: Double) -> Double {
        guard quality.isFinite else { return 0.8 }
        return min(1, max(0.1, quality))
    }

    /// Writes `image` as a JPEG. Returns the number of bytes written.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, quality: Double) throws -> Int {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { throw Failure.noDestination(url) }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQuality(quality)
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            // A half-written file is worse than none: `screens.jsonl` would name an
            // image no reader can open.
            try? FileManager.default.removeItem(at: url)
            throw Failure.encodingFailed(url)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.stenoPath)
        return (attributes?[.size] as? Int) ?? 0
    }

    /// A `CGImage` from the pixel buffer a `SCStream` delivered.
    ///
    /// `VTCreateCGImageFromCVPixelBuffer` is the direct route for the BGRA buffers the
    /// stream is configured to produce and needs no Core Image context; the
    /// `CIContext` path is the fallback for anything it declines, which is what a
    /// future pixel format or an HDR surface would look like.
    static func image(from pixelBuffer: CVPixelBuffer, context: CIContext) throws -> CGImage {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if status == noErr, let cgImage { return cgImage }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let fallback = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw Failure.noImage
        }
        return fallback
    }

    /// The Core Image context the fallback path uses.
    ///
    /// Built once and reused: a `CIContext` carries a Metal command queue and a set of
    /// compiled kernels, and creating one per frame would cost more than the encode.
    static func makeContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            // The frames are already at their final size; nothing here needs caching
            // between calls, and the cache would hold whole displays in memory.
            .cacheIntermediates: false
        ])
    }
}
