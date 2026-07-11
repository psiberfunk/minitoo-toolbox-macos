import Testing
import Foundation
@testable import DivoomMiniToo

/// Expected packets are built via DivoomRawFrame.build itself (the same
/// envelope function it's built with in production, already covered
/// independently by DivoomRawFrameTests) rather than by re-deriving the
/// checksum algorithm here -- these tests are about the chunking/announce
/// body layout, not re-proving the envelope math a second time.
private func u32le(_ n: Int) -> Data {
    Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
}

struct DivoomChunkedUploadTests {
    @Test func announceAndThreeChunksForNonMultiplePayload() {
        let payload = Data(0..<10) // 10 bytes: 0x00...0x09
        let packets = DivoomChunkedUpload.packets(cmd: 0x99, payload: payload, chunkSize: 4)

        #expect(packets.count == 4) // 1 announce + 3 chunks (4, 4, 2 bytes)

        let expectedAnnounce = DivoomRawFrame.build(cmd: 0x99, body: Data([0x00]) + u32le(10))
        #expect(packets[0] == expectedAnnounce)

        let expectedChunk0 = DivoomRawFrame.build(cmd: 0x99, body: Data([0x01]) + u32le(10) + Data([0x00, 0x00]) + payload[0..<4])
        #expect(packets[1] == expectedChunk0)

        let expectedChunk1 = DivoomRawFrame.build(cmd: 0x99, body: Data([0x01]) + u32le(10) + Data([0x01, 0x00]) + payload[4..<8])
        #expect(packets[2] == expectedChunk1)

        let expectedChunk2 = DivoomRawFrame.build(cmd: 0x99, body: Data([0x01]) + u32le(10) + Data([0x02, 0x00]) + payload[8..<10])
        #expect(packets[3] == expectedChunk2)
    }

    @Test func emptyPayloadProducesOnlyAnnounce() {
        let packets = DivoomChunkedUpload.packets(cmd: 0x99, payload: Data(), chunkSize: 4)
        #expect(packets.count == 1)
        #expect(packets[0] == DivoomRawFrame.build(cmd: 0x99, body: Data([0x00]) + u32le(0)))
    }

    @Test func payloadExactlyOneChunkProducesNoTrailingEmptyChunk() {
        let payload = Data(repeating: 0xCC, count: 4)
        let packets = DivoomChunkedUpload.packets(cmd: 0x99, payload: payload, chunkSize: 4)
        #expect(packets.count == 2) // announce + exactly 1 chunk, not 2
    }

    @Test func defaultChunkSizeIs256() {
        let payload = Data(repeating: 0xAA, count: 300)
        let packets = DivoomChunkedUpload.packets(cmd: 0x8B, payload: payload)
        #expect(packets.count == 3) // announce + 256-byte chunk + 44-byte chunk
    }

    /// Property check across many payload sizes (not just the hand-picked
    /// boundary cases above): concatenating every chunk's payload bytes back
    /// together, in order, must exactly reconstruct the original payload --
    /// no dropped bytes, no duplicated bytes, no reordering, regardless of
    /// how the size happens to divide against chunkSize.
    @Test func reconstructsOriginalPayloadAcrossManySizes() {
        for size in stride(from: 0, through: 600, by: 37) {
            let payload = Data((0..<size).map { UInt8($0 % 256) })
            let packets = DivoomChunkedUpload.packets(cmd: 0x77, payload: payload, chunkSize: 64)

            var reconstructed = Data()
            for packet in packets.dropFirst() { // skip the announce packet
                let bodyLen = packet.count - 7
                let body = packet.dropFirst(4).prefix(bodyLen)
                reconstructed.append(body.dropFirst(7)) // drop [0x01] + total_len_le32 + seq_le16
            }
            #expect(reconstructed == payload, "size \(size) failed to round-trip")
        }
    }

    /// chunkSize <= 0 used to hang forever (offset never advances past the
    /// clamp added to DivoomChunkedUpload.packets). Not reachable from any
    /// real call site today, but worth locking in now that it's guarded.
    @Test func degenerateChunkSizeDoesNotHang() {
        let packets = DivoomChunkedUpload.packets(cmd: 0x77, payload: Data([1, 2, 3]), chunkSize: 0)
        #expect(packets.count == 4) // announce + 3 chunks, clamped to chunkSize 1
    }
}
