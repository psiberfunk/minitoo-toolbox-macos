import Foundation
import CoreGraphics
import ImageIO

enum DivoomImageResizeError: Error {
    case loadFailed(String)
    case renderFailed(String)
}

/// Shared cover-crop + resize, replacing two independent Python copies of
/// the same ratio math: send_divoom_image.py's _cover_resize and
/// divoom_album.py's cmd_add_photo. CGImage.cropping(to:)'s rect uses a
/// top-left origin (confirmed empirically against a real test image, not
/// assumed) -- same convention as PIL's box coordinates -- so the crop math
/// below ports directly with no coordinate flip.
enum DivoomImageResize {
    /// - Parameter applyExifOrientation: send_divoom_image.py's still-image
    ///   path calls PIL's `ImageOps.exif_transpose` first; divoom_album.py's
    ///   photo path never has. That's an existing asymmetry between the two
    ///   scripts, not something this port should silently "fix" -- callers
    ///   pass `true`/`false` to match each feature's current behavior.
    static func coverResize(imageURL: URL, width: Int, height: Int, applyExifOrientation: Bool) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw DivoomImageResizeError.loadFailed("could not open \(imageURL.lastPathComponent)")
        }

        let cgImage: CGImage
        if applyExifOrientation {
            // CGImageSourceCreateThumbnailAtIndex with WithTransform=true is
            // ImageIO's own EXIF-orientation-aware decode path -- it bakes
            // the stored orientation into the returned pixel data, matching
            // what PIL's exif_transpose does, without hand-rolling the 8-case
            // EXIF orientation matrix ourselves. A generous max pixel size
            // avoids ever actually downsampling a real photo before our own
            // crop/resize below does the real work.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 8192,
            ]
            guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw DivoomImageResizeError.loadFailed("could not decode \(imageURL.lastPathComponent)")
            }
            cgImage = oriented
        } else {
            guard let plain = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw DivoomImageResizeError.loadFailed("could not decode \(imageURL.lastPathComponent)")
            }
            cgImage = plain
        }

        let srcWidth = Double(cgImage.width)
        let srcHeight = Double(cgImage.height)
        let dstRatio = Double(width) / Double(height)
        let srcRatio = srcWidth / srcHeight

        let cropRect: CGRect
        if srcRatio > dstRatio {
            let newWidth = (srcHeight * dstRatio).rounded()
            let left = ((srcWidth - newWidth) / 2).rounded(.down)
            cropRect = CGRect(x: left, y: 0, width: newWidth, height: srcHeight)
        } else {
            let newHeight = (srcWidth / dstRatio).rounded()
            let top = ((srcHeight - newHeight) / 2).rounded(.down)
            cropRect = CGRect(x: 0, y: top, width: srcWidth, height: newHeight)
        }
        guard let cropped = cgImage.cropping(to: cropRect) else {
            throw DivoomImageResizeError.renderFailed("crop to \(cropRect) failed")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DivoomImageResizeError.renderFailed("CGContext creation failed")
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw DivoomImageResizeError.renderFailed("resize render failed")
        }
        return output
    }

    /// Tightly-packed RGB24 bytes (no alpha), row-major top-to-bottom --
    /// what send_divoom_image.py's payload format requires per frame.
    static func rgb24Bytes(from image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DivoomImageResizeError.renderFailed("CGContext creation failed")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var srcIndex = 0
        var dstIndex = 0
        for _ in 0..<(width * height) {
            rgb[dstIndex] = rgba[srcIndex]
            rgb[dstIndex + 1] = rgba[srcIndex + 1]
            rgb[dstIndex + 2] = rgba[srcIndex + 2]
            srcIndex += 4
            dstIndex += 3
        }
        return Data(rgb)
    }
}
