import Foundation
import CoreGraphics
import CoreImage

enum DivoomMediaEncodeError: Error {
    case invalidDimensions(String)
    case frameLengthMismatch(String)
    case ffmpegFailed(String)
}

/// Native port of send_divoom_image.py's still-image path: _normalize_dims,
/// _animation_payload (single-frame case), build_payload, build_packets.
/// The video/GIF path (build_video_payload) is ported further down --
/// ffmpeg still does all scale/crop/fps/eq decoding exactly as before, just
/// invoked directly by Swift's Process instead of by a Python subprocess.
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

    // MARK: - Video / GIF (build_video_payload port)

    /// Matches send_divoom_image.py's VIDEO_SUFFIXES -- GIF/APNG route
    /// through ffmpeg decode too, not a still-image reader.
    static let videoSuffixes: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "gif", "apng"]

    static func buildVideoPayload(
        videoURL: URL, ffmpegPath: String, speed: Int, level: Int32 = 17, width: Int = 128, height: Int = 128,
        fps: Double? = nil, maxFrames: Int = 60, windowLog: Int32 = 17, start: Double? = nil, duration: Double? = nil,
        brightness: Double = 0.0, contrast: Double = 1.0, saturation: Double = 1.0,
        posterizeBits: Int? = nil, sharpen: Double = 1.0
    ) throws -> (payload: Data, preview: CGImage, frameCount: Int) {
        let (w, h) = try normalizeDims(width: width, height: height)
        guard maxFrames > 0, maxFrames <= 255 else {
            throw DivoomMediaEncodeError.invalidDimensions("max_frames must be in the range 1..255")
        }

        // ffmpeg keeps doing scale/crop/fps/eq exactly as before -- only the
        // process that invokes it changed (Swift's Process instead of
        // Python's subprocess.run).
        var vfParts: [String] = []
        if let fps { vfParts.append("fps=\(fps)") }
        if brightness != 0.0 || contrast != 1.0 || saturation != 1.0 {
            vfParts.append("eq=brightness=\(brightness):contrast=\(contrast):saturation=\(saturation)")
        }
        vfParts.append("scale=\(w):\(h):force_original_aspect_ratio=increase")
        vfParts.append("crop=\(w):\(h)")

        var args = ["-hide_banner", "-loglevel", "error"]
        if let start { args += ["-ss", String(start)] }
        args += ["-i", videoURL.path]
        if let duration { args += ["-t", String(duration)] }
        args += ["-vf", vfParts.joined(separator: ","), "-frames:v", String(maxFrames), "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]

        let stdout: Data
        do {
            stdout = try DivoomProcess.runCapturingData(ffmpegPath, args).stdout
        } catch DivoomProcessError.nonZeroExit(_, let stderr) {
            throw DivoomMediaEncodeError.ffmpegFailed(stderr)
        }

        let frameLen = w * h * 3
        guard stdout.count >= frameLen else {
            throw DivoomMediaEncodeError.frameLengthMismatch("ffmpeg produced no complete video frames")
        }
        let frameCount = stdout.count / frameLen
        var rawFrames: [Data] = []
        var preview: CGImage?
        for i in 0..<frameCount {
            var frame = stdout.subdata(in: (i * frameLen)..<((i + 1) * frameLen))
            if let posterizeBits, posterizeBits < 8 {
                frame = try applyPosterize(frame, width: w, height: h, bits: posterizeBits)
            }
            if sharpen != 1.0 {
                frame = try applySharpen(frame, width: w, height: h, amount: sharpen)
            }
            if preview == nil {
                preview = try cgImage(fromRGB24: frame, width: w, height: h)
            }
            rawFrames.append(frame)
        }
        guard let previewImage = preview else {
            throw DivoomMediaEncodeError.frameLengthMismatch("no frames decoded")
        }
        let payload = try animationPayload(rawFrames: rawFrames, width: w, height: h, speed: speed, level: level, windowLog: windowLog)
        return (payload, previewImage, frameCount)
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private static func cgImage(fromRGB24 data: Data, width: Int, height: Int) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let rgb = rawPtr.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                rgba[i * 4] = rgb[i * 3]
                rgba[i * 4 + 1] = rgb[i * 3 + 1]
                rgba[i * 4 + 2] = rgb[i * 3 + 2]
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else {
            throw DivoomMediaEncodeError.frameLengthMismatch("raw-frame CGImage creation failed")
        }
        return image
    }

    /// Pillow's ImageOps.posterize(bits) truncates the top `bits` bits per
    /// channel; CIColorPosterize instead quantizes into 2^bits evenly-spaced
    /// levels -- a different curve, but this only affects on-device visual
    /// quality (never protocol correctness: dimensions/frame-count/valid
    /// zstd payload are unaffected), matching this port's general allowance
    /// for non-pixel-identical output. Not exercised by today's UI defaults
    /// (posterize_bits is never passed by the app).
    private static func applyPosterize(_ rgb: Data, width: Int, height: Int, bits: Int) throws -> Data {
        let cg = try cgImage(fromRGB24: rgb, width: width, height: height)
        guard let filter = CIFilter(name: "CIColorPosterize") else { return rgb }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(Double(1 << bits), forKey: "inputLevels")
        guard let output = filter.outputImage,
              let rendered = ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { return rgb }
        return try DivoomImageResize.rgb24Bytes(from: rendered)
    }

    /// Pillow's ImageEnhance.Sharpness(factor) and CISharpenLuminance's
    /// inputSharpness are different algorithms (unsharp-mask blend factor
    /// vs. luminance-sharpen intensity) -- visual-quality tuning only, same
    /// allowance as posterize above. Not exercised by today's UI defaults
    /// (sharpen is never passed as anything but 1.0, which skips this).
    private static func applySharpen(_ rgb: Data, width: Int, height: Int, amount: Double) throws -> Data {
        let cg = try cgImage(fromRGB24: rgb, width: width, height: height)
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return rgb }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(amount - 1.0, forKey: kCIInputSharpnessKey)
        guard let output = filter.outputImage,
              let rendered = ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { return rgb }
        return try DivoomImageResize.rgb24Bytes(from: rendered)
    }
}
