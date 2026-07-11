import Foundation
import CoreGraphics

enum DivoomMediaEncodeError: Error {
    case invalidDimensions(String)
    case frameLengthMismatch(String)
}

/// Native port of send_divoom_image.py's still-image path: _normalize_dims,
/// _animation_payload (single-frame case), build_payload, build_packets.
/// The video/GIF path (build_video_payload, needing ffmpeg + per-frame
/// posterize/sharpen) is a separate, later port -- see DivoomMediaEncode's
/// video extension once added.
enum DivoomMediaEncode {
    // Physical panel is 160 wide x 128 tall (confirmed on real hardware);
    // the device's own 16px block-addressing units are 10 cols x 8 rows.
    static let panelWidth = 160
    static let panelHeight = 128
    private static let cmdAppNewGif2020: UInt8 = 0x8B

    static func normalizeDims(width: Int, height: Int) throws -> (Int, Int) {
        guard width > 0, width % 16 == 0, width <= panelWidth else {
            throw DivoomMediaEncodeError.invalidDimensions("width must be a positive multiple of 16 up to \(panelWidth)")
        }
        guard height > 0, height % 16 == 0, height <= panelHeight else {
            throw DivoomMediaEncodeError.invalidDimensions("height must be a positive multiple of 16 up to \(panelHeight)")
        }
        return (width, height)
    }

    private static func u16be(_ n: Int) -> Data {
        Data([UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    private static func u32be(_ n: Int) -> Data {
        Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    /// From W2.c.f() / PROTOCOL.md: marker/frame/speed/rows/cols + big-endian
    /// compressed length + zstd frame.
    static func animationPayload(
        rawFrames: [Data], width: Int, height: Int, speed: Int, level: Int32 = 17, windowLog: Int32 = 17
    ) throws -> Data {
        guard !rawFrames.isEmpty else {
            throw DivoomMediaEncodeError.invalidDimensions("at least one frame is required")
        }
        guard rawFrames.count <= 255 else {
            throw DivoomMediaEncodeError.invalidDimensions("Divoom animation frame count is one byte; use <= 255 frames")
        }
        let frameLen = width * height * 3
        for (i, raw) in rawFrames.enumerated() {
            guard raw.count == frameLen else {
                throw DivoomMediaEncodeError.frameLengthMismatch("frame \(i) has \(raw.count) bytes, expected \(frameLen)")
            }
        }
        var raw = Data(capacity: frameLen * rawFrames.count)
        for f in rawFrames { raw.append(f) }
        let zbytes = try DivoomZstd.compress(raw, level: level, windowLog: windowLog)

        let rowBlocks = height / 16
        let colBlocks = width / 16
        var header = Data([0x25, UInt8(rawFrames.count)])
        header.append(u16be(speed))
        header.append(contentsOf: [UInt8(rowBlocks), UInt8(colBlocks)])
        header.append(u32be(zbytes.count))
        return header + zbytes
    }

    static func buildImagePayload(
        imageURL: URL, speed: Int = 1000, level: Int32 = 17, width: Int = 128, height: Int = 128, windowLog: Int32 = 17
    ) throws -> (payload: Data, preview: CGImage) {
        let (w, h) = try normalizeDims(width: width, height: height)
        let resized = try DivoomImageResize.coverResize(imageURL: imageURL, width: w, height: h, applyExifOrientation: true)
        let rgb = try DivoomImageResize.rgb24Bytes(from: resized)
        let payload = try animationPayload(rawFrames: [rgb], width: w, height: h, speed: speed, level: level, windowLog: windowLog)
        return (payload, resized)
    }

    static func buildPackets(payload: Data) -> [Data] {
        DivoomChunkedUpload.packets(cmd: cmdAppNewGif2020, payload: payload)
    }
}
