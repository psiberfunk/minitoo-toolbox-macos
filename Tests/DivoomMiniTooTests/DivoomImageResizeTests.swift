import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DivoomMiniToo

private func solidColorImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = pixels.withUnsafeMutableBytes { ptr in
        CGContext(
            data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
    return context!.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

struct DivoomImageResizeTests {
    // MARK: - rgb24Bytes (pure in-memory, no file I/O needed)

    @Test func rgb24BytesStripsAlphaInRowMajorOrder() throws {
        // 2x2 image, one distinct color per pixel, alpha=255 so premultiplication
        // doesn't alter the RGB values -- exact byte comparison is meaningful.
        var pixels: [UInt8] = [
            255, 0, 0, 255, // (0,0) red
            0, 255, 0, 255, // (1,0) green
            0, 0, 255, 255, // (0,1) blue
            255, 255, 0, 255, // (1,1) yellow
        ]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = pixels.withUnsafeMutableBytes { ptr in
            CGContext(
                data: ptr.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        let image = try #require(context?.makeImage())

        let rgb = try DivoomImageResize.rgb24Bytes(from: image)
        #expect(rgb == Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]))
    }

    @Test func rgb24BytesLengthIsWidthTimesHeightTimesThree() throws {
        let image = solidColorImage(width: 5, height: 3, r: 10, g: 20, b: 30)
        let rgb = try DivoomImageResize.rgb24Bytes(from: image)
        #expect(rgb.count == 5 * 3 * 3)
    }

    // MARK: - coverResize (needs a real file on disk -- synthesized at test time, no fixture)

    @Test func coverResizeCropsWideSourceToSquareTarget() throws {
        // srcRatio (2.0) > dstRatio (1.0) -> crops left/right, keeps full height.
        let source = solidColorImage(width: 200, height: 100, r: 1, g: 2, b: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        writePNG(source, to: url)

        let resized = try DivoomImageResize.coverResize(imageURL: url, width: 100, height: 100, applyExifOrientation: false)
        #expect(resized.width == 100)
        #expect(resized.height == 100)
    }

    @Test func coverResizeCropsTallSourceToSquareTarget() throws {
        // srcRatio (0.5) < dstRatio (1.0) -> crops top/bottom, keeps full width.
        let source = solidColorImage(width: 100, height: 200, r: 1, g: 2, b: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        writePNG(source, to: url)

        let resized = try DivoomImageResize.coverResize(imageURL: url, width: 100, height: 100, applyExifOrientation: false)
        #expect(resized.width == 100)
        #expect(resized.height == 100)
    }

    @Test func coverResizeToNonSquarePanelDimensions() throws {
        let source = solidColorImage(width: 300, height: 300, r: 1, g: 2, b: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        writePNG(source, to: url)

        // Full 160x128 panel target -- exercises the non-1:1 dstRatio branch.
        let resized = try DivoomImageResize.coverResize(imageURL: url, width: 160, height: 128, applyExifOrientation: false)
        #expect(resized.width == 160)
        #expect(resized.height == 128)
    }
}
