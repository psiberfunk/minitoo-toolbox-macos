import Testing
import Foundation
import CZstd
@testable import MiniTooToolbox

enum ZstdTestDecompressError: Error {
    case unknownContentSize
    case decompressFailed(String)
}

/// Test-only decompress wrapper -- production code (DivoomZstd.swift) never
/// needs to decompress, only these tests do, so this stays here rather than
/// in the shipped module. CZstd is a direct test-target dependency (see
/// Package.swift) precisely so this can call the real vendored zstd
/// decompressor instead of just inspecting compressed bytes structurally.
private func zstdDecompress(_ input: Data) throws -> Data {
    let contentSize: UInt64 = input.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, input.count) }
    guard contentSize != UInt64.max, contentSize != UInt64.max - 1 else { // ZSTD_CONTENTSIZE_UNKNOWN / _ERROR
        throw ZstdTestDecompressError.unknownContentSize
    }
    var dst = Data(count: Int(contentSize))
    let dstCapacity = dst.count
    let written: Int = dst.withUnsafeMutableBytes { dstPtr in
        input.withUnsafeBytes { srcPtr in
            ZSTD_decompress(dstPtr.baseAddress, dstCapacity, srcPtr.baseAddress, input.count)
        }
    }
    guard ZSTD_isError(written) == 0 else {
        throw ZstdTestDecompressError.decompressFailed(String(cString: ZSTD_getErrorName(written)))
    }
    #expect(written == dstCapacity)
    return dst
}

struct DivoomZstdTests {
    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    @Test func compressedOutputStartsWithZstdMagic() throws {
        let input = "Hello, Divoom MiniToo!".data(using: .utf8)!
        let compressed = try DivoomZstd.compress(input)
        #expect(Array(compressed.prefix(4)) == Self.zstdMagic)
    }

    @Test func compressionIsDeterministic() throws {
        let input = Data((0..<4096).map { UInt8($0 % 251) })
        let first = try DivoomZstd.compress(input)
        let second = try DivoomZstd.compress(input)
        #expect(first == second)
    }

    @Test func handlesEmptyInputWithoutThrowing() throws {
        let compressed = try DivoomZstd.compress(Data())
        #expect(Array(compressed.prefix(4)) == Self.zstdMagic)
    }

    // MARK: - Round-trip (the real correctness check the tests above can't do)

    @Test func compressThenDecompressRoundTripsText() throws {
        let input = "Hello, Divoom MiniToo! Round-trip me.".data(using: .utf8)!
        let compressed = try DivoomZstd.compress(input)
        let decompressed = try zstdDecompress(compressed)
        #expect(decompressed == input)
    }

    @Test func compressThenDecompressRoundTripsBinaryRGB24LikeData() throws {
        // Same shape of data DivoomMediaEncode actually compresses: a raw
        // RGB24 frame buffer, not text -- exercises non-ASCII byte values
        // and a size in the same ballpark as a real 128x128x3 frame.
        let input = Data((0..<(128 * 128 * 3)).map { UInt8(($0 * 37) % 256) })
        let compressed = try DivoomZstd.compress(input)
        let decompressed = try zstdDecompress(compressed)
        #expect(decompressed == input)
    }

    @Test func compressThenDecompressRoundTripsEmptyInput() throws {
        let compressed = try DivoomZstd.compress(Data())
        let decompressed = try zstdDecompress(compressed)
        #expect(decompressed == Data())
    }

    @Test func decompressedContentSizeIsDeclaredInFrame() throws {
        let input = Data(repeating: 0xAB, count: 10_000)
        let compressed = try DivoomZstd.compress(input)
        let declaredSize = compressed.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, compressed.count) }
        #expect(declaredSize == UInt64(input.count))
    }
}
