import Testing
import Foundation
@testable import DivoomMiniToo

/// Only lib/common + lib/compress were vendored from zstd (see
/// tools/vendor/zstd-1.5.7/lib/ -- no decompress/ subdirectory), so there's
/// no decompressor linked in to round-trip against. These tests stick to
/// what's actually verifiable without one: the standard zstd frame magic,
/// and that compression is deterministic.
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
}
