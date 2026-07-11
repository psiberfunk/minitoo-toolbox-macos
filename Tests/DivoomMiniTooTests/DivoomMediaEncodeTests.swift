import Testing
import Foundation
@testable import DivoomMiniToo

struct DivoomMediaEncodeTests {
    @Test func acceptsFullPanelDimensions() throws {
        let (w, h) = try DivoomMediaEncode.normalizeDims(width: 160, height: 128)
        #expect(w == 160)
        #expect(h == 128)
    }

    @Test func acceptsSmallerMultipleOf16() throws {
        let (w, h) = try DivoomMediaEncode.normalizeDims(width: 16, height: 16)
        #expect(w == 16)
        #expect(h == 16)
    }

    @Test(arguments: [
        (0, 128), (-16, 128), (15, 128), // width invalid: zero, negative, not a multiple of 16
        (176, 128), // width exceeds panel max (176 > 160), even though it's a multiple of 16
    ])
    func rejectsInvalidWidth(width: Int, height: Int) {
        #expect(throws: DivoomMediaEncodeError.self) {
            try DivoomMediaEncode.normalizeDims(width: width, height: height)
        }
    }

    @Test(arguments: [
        (128, 0), (128, -16), (128, 15),
        (128, 144), // height exceeds panel max (144 > 128), multiple of 16 though
    ])
    func rejectsInvalidHeight(width: Int, height: Int) {
        #expect(throws: DivoomMediaEncodeError.self) {
            try DivoomMediaEncode.normalizeDims(width: width, height: height)
        }
    }

    @Test func animationPayloadHeaderIsSelfConsistent() throws {
        let width = 16, height = 16, speed = 500
        let frame = Data(repeating: 0x42, count: width * height * 3) // synthetic RGB24 frame
        let payload = try DivoomMediaEncode.animationPayload(rawFrames: [frame], width: width, height: height, speed: speed)

        // Header: 0x25 <frameCount> <speed_be16> <rowBlocks> <colBlocks> <zLen_be32> <zstd bytes...>
        #expect(payload[0] == 0x25)
        #expect(payload[1] == 1) // frame count
        #expect(payload[2] == 0x01) // speed=500=0x01F4, high byte
        #expect(payload[3] == 0xF4) // low byte
        #expect(payload[4] == 1) // rowBlocks = 16/16
        #expect(payload[5] == 1) // colBlocks = 16/16

        let declaredZLen = (UInt32(payload[6]) << 24) | (UInt32(payload[7]) << 16) | (UInt32(payload[8]) << 8) | UInt32(payload[9])
        let actualZstdBytes = payload.count - 10
        #expect(Int(declaredZLen) == actualZstdBytes)
        #expect(actualZstdBytes > 0)
    }

    @Test func animationPayloadRejectsMismatchedFrameLength() {
        let wrongSizeFrame = Data(repeating: 0x00, count: 10) // not width*height*3
        #expect(throws: DivoomMediaEncodeError.self) {
            try DivoomMediaEncode.animationPayload(rawFrames: [wrongSizeFrame], width: 16, height: 16, speed: 100)
        }
    }

    @Test func animationPayloadRejectsEmptyFrameList() {
        #expect(throws: DivoomMediaEncodeError.self) {
            try DivoomMediaEncode.animationPayload(rawFrames: [], width: 16, height: 16, speed: 100)
        }
    }

    @Test func animationPayloadRejectsMoreThan255Frames() {
        let frame = Data(repeating: 0x00, count: 16 * 16 * 3)
        let frames = Array(repeating: frame, count: 256)
        #expect(throws: DivoomMediaEncodeError.self) {
            try DivoomMediaEncode.animationPayload(rawFrames: frames, width: 16, height: 16, speed: 100)
        }
    }
}
