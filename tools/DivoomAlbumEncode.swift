import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Native port of divoom_album.py: persistent on-device photo gallery
/// upload. Stills only (JPEG), no zstd -- see that file's module docstring
/// for the full reverse-engineered protocol story.
enum DivoomAlbumEncode {
    static let panelWidth = 160
    static let panelHeight = 128
    private static let blobMarker: UInt8 = 0x1F
    private static let sppLocalPicture: UInt8 = 0x8F

    struct Result {
        let packetsPath: URL
        let previewImage: CGImage
        let jpegByteCount: Int
    }

    private static let deviceId = 600111083
    private static let token = 1777741943
    private static let userId = 404779143

    static func photoEnterPacket() -> Data? {
        let job: [String: Any] = [
            "Command": "Photo/Enter",
            "DeviceId": deviceId,
            "Token": token,
            "UserId": userId,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else { return nil }
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }

    static func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DivoomImageResizeError.renderFailed("JPEG destination creation failed")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw DivoomImageResizeError.renderFailed("JPEG encode failed")
        }
        return data as Data
    }

    private static func u16be(_ n: Int) -> Data {
        Data([UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    private static func u32be(_ n: Int) -> Data {
        Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    static func buildPhotoBlob(jpegData: Data, rowBlocks: Int, colBlocks: Int, speed: Int) -> Data {
        var blob = Data([blobMarker, 1])
        blob.append(u16be(speed))
        blob.append(contentsOf: [UInt8(rowBlocks), UInt8(colBlocks)])
        blob.append(u32be(jpegData.count))
        blob.append(jpegData)
        return blob
    }

    /// Mirrors cmd_add_photo: cover-resize (no EXIF transpose, matching the
    /// existing Python behavior -- see DivoomImageResize's doc comment),
    /// JPEG-encode, wrap in the blob header, build Photo/Enter + chunked
    /// upload packets, and write them to a per-call-site-chosen output dir.
    static func buildAlbumUpload(
        imageURL: URL, outDir: URL, width: Int = panelWidth, height: Int = panelHeight,
        quality: CGFloat = 0.9, speed: Int = 2000
    ) throws -> Result {
        let resized = try DivoomImageResize.coverResize(imageURL: imageURL, width: width, height: height, applyExifOrientation: false)
        let jpegData = try encodeJPEG(resized, quality: quality)
        let blob = buildPhotoBlob(jpegData: jpegData, rowBlocks: height / 16, colBlocks: width / 16, speed: speed)

        guard let enterPacket = photoEnterPacket() else {
            throw DivoomImageResizeError.renderFailed("Photo/Enter JSON encode error")
        }
        var packets = [enterPacket]
        packets.append(contentsOf: DivoomChunkedUpload.packets(cmd: sppLocalPicture, payload: blob))

        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let path = DivoomRawFrame.writePacketsFile(packets, name: "album-add-photo", in: outDir)
        return Result(packetsPath: path, previewImage: resized, jpegByteCount: jpegData.count)
    }
}
