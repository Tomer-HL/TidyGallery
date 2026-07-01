//
//  BlurDetector.swift
//  TidyGallery
//
//  Sharpness estimation via variance-of-Laplacian, computed on the CPU with
//  vImage/Accelerate. Higher variance == more high-frequency detail == sharper.
//
//  Caveat (documented deliberately): Laplacian variance is content-dependent —
//  a flat wall scores low even when perfectly in focus. That's why the value
//  returned here is a *relative* sharpness signal; `ShotScorer` only ever
//  compares it BETWEEN photos in the same stack (same-ish content), which is
//  exactly the situation where the metric is reliable.
//

import Foundation
import Accelerate
import CoreGraphics

enum BlurDetector {

    /// Returns a normalised sharpness score in `[0, 1]` for a CGImage.
    ///
    /// Pipeline: convert to planar 8-bit luminance → convolve with a 3×3
    /// Laplacian kernel → take the variance of the response → squash to `[0,1]`
    /// with a saturating curve so scores are comparable across images.
    static func sharpness(of image: CGImage) -> Double {
        guard let variance = laplacianVariance(of: image) else { return 0 }
        // Map raw variance through a saturating curve. The constant sets the
        // "half-saturation" point; tune against real photos. Chosen so typical
        // in-focus phone photos land ~0.6–0.9 and obvious blur lands <0.3.
        let halfSaturation = 500.0
        return variance / (variance + halfSaturation)
    }

    /// Raw variance of the Laplacian response, or `nil` if conversion fails.
    static func laplacianVariance(of image: CGImage) -> Double? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }

        // 1. Draw into an 8-bit grayscale buffer.
        guard let gray = grayscaleBuffer(from: image, width: width, height: height) else {
            return nil
        }

        var source = gray
        defer { free(source.data) }

        // 2. Allocate a destination buffer for the convolution result.
        guard let destData = malloc(width * height) else { return nil }
        var dest = vImage_Buffer(
            data: destData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        defer { free(dest.data) }

        // 3. 3×3 Laplacian kernel (edge response).
        var kernel: [Int16] = [
            0, -1,  0,
           -1,  4, -1,
            0, -1,  0
        ]
        let divisor: Int32 = 1
        let error = vImageConvolve_Planar8(
            &source, &dest, nil, 0, 0,
            &kernel, 3, 3,
            divisor, 0,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard error == kvImageNoError else { return nil }

        // 4. Convert response bytes to Float and compute variance.
        let count = width * height
        let responsePtr = dest.data.assumingMemoryBound(to: UInt8.self)
        var floats = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: UnsafeBufferPointer(start: responsePtr, count: count), to: &floats)

        var mean: Float = 0
        vDSP_meanv(floats, 1, &mean, vDSP_Length(count))
        var meanSquare: Float = 0
        vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(count))
        let variance = Double(meanSquare) - Double(mean * mean)
        return max(0, variance)
    }

    /// Renders a CGImage into a freshly-allocated planar 8-bit grayscale
    /// `vImage_Buffer`. Caller owns `.data` and must `free` it.
    private static func grayscaleBuffer(from image: CGImage, width: Int, height: Int) -> vImage_Buffer? {
        guard let data = malloc(width * height) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            free(data)
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return vImage_Buffer(
            data: data,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
    }
}
