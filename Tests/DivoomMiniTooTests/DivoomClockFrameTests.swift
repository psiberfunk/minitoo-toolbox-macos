import Testing
import Foundation
@testable import DivoomMiniToo

struct DivoomClockFrameTests {
    @Test(arguments: [
        ("1", 984), ("custom1", 984), ("face1", 984),
        ("2", 986), ("custom2", 986), ("face2", 986),
        ("3", 988), ("custom3", 988), ("face3", 988),
    ])
    func resolvesKnownShortcuts(shortcut: String, expectedId: Int) {
        #expect(DivoomClockFrame.resolveClockId(shortcut) == expectedId)
    }

    @Test func resolutionIsCaseInsensitive() {
        #expect(DivoomClockFrame.resolveClockId("CUSTOM2") == 986)
        #expect(DivoomClockFrame.resolveClockId("Face3") == 988)
    }

    @Test func numericShortcutPassesThroughWhenNotAKnownAlias() {
        // "1"/"2"/"3" are the known aliases above; an arbitrary numeric
        // ClockId not in the shortcut table should still resolve via the
        // Int(shortcut) fallback.
        #expect(DivoomClockFrame.resolveClockId("999") == 999)
    }

    @Test func garbageShortcutResolvesToNil() {
        #expect(DivoomClockFrame.resolveClockId("bogus") == nil)
    }

    /// Field values below are the exact captured Channel/SetClockSelectId
    /// body from PROTOCOL.md's "Custom face selection" section (ClockId
    /// 984 case) -- decode the envelope this function builds and compare
    /// every field against that capture, rather than re-deriving the
    /// envelope's checksum bytes by hand.
    @Test func selectPacketBodyMatchesCapturedJSON() throws {
        guard let frame = DivoomClockFrame.selectPacket(clockId: 984) else {
            Issue.record("selectPacket returned nil")
            return
        }
        // Envelope layout: 0x01 <len_lo> <len_hi> <cmd> <body...> <checksum_lo> <checksum_hi> 0x02
        let bodyLen = frame.count - 7
        let body = frame.dropFirst(4).prefix(bodyLen)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])

        #expect(json["ClockId"] as? Int == 984)
        #expect(json["Command"] as? String == "Channel/SetClockSelectId")
        #expect(json["DeviceId"] as? Int == 600111083)
        #expect(json["DevicePassword"] as? Int == 1777733348)
        #expect(json["Language"] as? String == "en")
        #expect(json["LcdIndependence"] as? Int == 0)
        #expect(json["LcdIndex"] as? Int == 0)
        #expect(json["PageIndex"] as? Int == 0)
        #expect(json["ParentClockId"] as? Int == 0)
        #expect(json["ParentItemId"] as? String == "")
        #expect(json["Token"] as? Int == 1777741943)
        #expect(json["UserId"] as? Int == 404779143)
    }
}
