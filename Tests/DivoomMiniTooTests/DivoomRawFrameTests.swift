import Testing
import Foundation
@testable import DivoomMiniToo

/// Expected bytes below are independently computed from PROTOCOL.md's
/// documented reference algorithm (frame(cmd, body) in the "Generic frame
/// format" section), not copied from the doc's own worked example -- that
/// example (the 0x8b announce packet for an 11937-byte payload) turned out
/// to have a checksum typo when cross-checked against the same reference
/// algorithm, so these cases were computed fresh instead of trusted as-is.
struct DivoomRawFrameTests {
    @Test func singleByteBody() {
        let frame = DivoomRawFrame.build(cmd: 0x01, body: Data([0xAB]))
        #expect(frame == Data([0x01, 0x04, 0x00, 0x01, 0xAB, 0xB0, 0x00, 0x02]))
    }

    @Test func emptyBody() {
        let frame = DivoomRawFrame.build(cmd: 0x02, body: Data())
        #expect(frame == Data([0x01, 0x03, 0x00, 0x02, 0x05, 0x00, 0x02]))
    }

    @Test func multiByteBody() {
        let frame = DivoomRawFrame.build(cmd: 0x8B, body: Data([0x00, 0x01, 0x02, 0x03, 0x04]))
        #expect(frame == Data([0x01, 0x08, 0x00, 0x8B, 0x00, 0x01, 0x02, 0x03, 0x04, 0x9D, 0x00, 0x02]))
    }

    @Test func declaredLengthIsBodyCountPlusThree() {
        let body = Data(repeating: 0x00, count: 20)
        let frame = DivoomRawFrame.build(cmd: 0x10, body: body)
        let declared = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(declared == UInt16(body.count + 3))
    }

    @Test func envelopeStructure() {
        let body = Data([0x11, 0x22, 0x33])
        let frame = DivoomRawFrame.build(cmd: 0x42, body: body)
        // 0x01 <len_lo> <len_hi> <cmd> <body...> <checksum_lo> <checksum_hi> 0x02
        #expect(frame.first == 0x01)
        #expect(frame.last == 0x02)
        #expect(frame[3] == 0x42)
        #expect(frame.count == 7 + body.count)
    }
}
