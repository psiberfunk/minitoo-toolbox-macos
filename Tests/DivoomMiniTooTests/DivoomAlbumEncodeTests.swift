import Testing
import Foundation
@testable import MiniTooToolbox

struct DivoomAlbumEncodeTests {
    /// Matches PROTOCOL.md's documented photo blob layout (0x1F marker, frame
    /// count, speed_be16, rowBlocks, colBlocks, jpegLen_be32, jpeg bytes)
    /// with speed=2000/8x10 blocks, the same example values the doc uses.
    @Test func headerLayoutForSmallJPEG() {
        let jpeg = Data([0xFF, 0xD8]) // minimal JPEG SOI marker, stand-in payload
        let blob = DivoomAlbumEncode.buildPhotoBlob(jpegData: jpeg, rowBlocks: 8, colBlocks: 10, speed: 2000)
        #expect(blob == Data([0x1F, 0x01, 0x07, 0xD0, 0x08, 0x0A, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xD8]))
    }

    @Test func jpegLengthFieldIsBigEndianU32ForLargerPayloads() {
        let jpeg = Data(repeating: 0x42, count: 300) // exercises the 2nd length byte (300 > 0xFF)
        let blob = DivoomAlbumEncode.buildPhotoBlob(jpegData: jpeg, rowBlocks: 8, colBlocks: 10, speed: 2000)
        let declared = (UInt32(blob[6]) << 24) | (UInt32(blob[7]) << 16) | (UInt32(blob[8]) << 8) | UInt32(blob[9])
        #expect(declared == 300)
        #expect(blob.count == 10 + 300)
        #expect(blob.suffix(300) == jpeg)
    }

    @Test func photoEnterPacketIsWellFormedEnvelope() throws {
        let frame = try #require(DivoomAlbumEncode.photoEnterPacket())
        #expect(frame.first == 0x01)
        #expect(frame.last == 0x02)
    }
}
