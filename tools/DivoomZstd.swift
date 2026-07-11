import Foundation
import CZstd

/// Native zstd compression, replacing Python's `zstandard.ZstdCompressionParameters.from_level(level, window_log=..., write_content_size=True)`.
/// Backed by the vendored zstd 1.5.7 sources (tools/vendor/zstd-1.5.7/,
/// compression-only) via the bridging header.
enum DivoomZstdError: Error {
    case compressionFailed(String)
}

enum DivoomZstd {
    static func compress(_ input: Data, level: Int32 = 17, windowLog: Int32 = 17) throws -> Data {
        guard let cctx = ZSTD_createCCtx() else {
            throw DivoomZstdError.compressionFailed("ZSTD_createCCtx failed")
        }
        defer { ZSTD_freeCCtx(cctx) }

        var rc = ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, level)
        guard ZSTD_isError(rc) == 0 else {
            throw DivoomZstdError.compressionFailed("set compressionLevel: \(String(cString: ZSTD_getErrorName(rc)))")
        }
        rc = ZSTD_CCtx_setParameter(cctx, ZSTD_c_windowLog, windowLog)
        guard ZSTD_isError(rc) == 0 else {
            throw DivoomZstdError.compressionFailed("set windowLog: \(String(cString: ZSTD_getErrorName(rc)))")
        }

        let bound = ZSTD_compressBound(input.count)
        var dst = Data(count: bound)

        let written: Int = dst.withUnsafeMutableBytes { dstPtr in
            input.withUnsafeBytes { srcPtr in
                ZSTD_compress2(cctx, dstPtr.baseAddress, bound, srcPtr.baseAddress, input.count)
            }
        }
        guard ZSTD_isError(written) == 0 else {
            throw DivoomZstdError.compressionFailed(String(cString: ZSTD_getErrorName(written)))
        }
        dst.removeSubrange(written..<dst.count)
        return dst
    }
}
