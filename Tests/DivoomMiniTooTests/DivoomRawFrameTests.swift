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

    @Test func countdownStartUsesCapturedToolThreeBody() {
        // Android HCI capture: one-minute Countdown start is 0x72 [3,1,1,0].
        let body = Data([0x03, 0x01, 0x01, 0x00])
        let frame = DivoomRawFrame.build(cmd: 0x72, body: body)
        #expect(frame[3] == 0x72)
        #expect(Data(frame[4..<8]) == body)
        #expect(UInt16(frame[1]) | (UInt16(frame[2]) << 8) == 7)
    }

    @Test func countdownDurationAcceptsBoundedNumericTime() {
        #expect(CountdownModel.parseDuration("01:05") == 65)
        #expect(CountdownModel.parseDuration("99:59") == 5_999)
        #expect(CountdownModel.parseDuration("00:00") == nil)
        #expect(CountdownModel.parseDuration("100:00") == nil)
        #expect(CountdownModel.parseDuration("01:60") == nil)
        #expect(CountdownModel.parseDuration("hello") == nil)
    }

    @Test func countdownDurationSanitizesImpossibleLiveInput() {
        #expect(CountdownModel.sanitizedDurationInput("01:999") == "01:")
        #expect(CountdownModel.sanitizedDurationInput("999:00") == "99:00")
        #expect(CountdownModel.sanitizedDurationInput("ab01:05") == "01:05")
        #expect(CountdownModel.sanitizedDurationInput("01:59") == "01:59")
    }

    @Test func customClockTimeRequiresCompleteValidComponents() {
        let valid = ClockSyncModel.timeComponents(hour: "23", minute: "59", second: "07")
        #expect(valid?.hour == 23)
        #expect(valid?.minute == 59)
        #expect(valid?.second == 7)
        #expect(ClockSyncModel.timeComponents(hour: "24", minute: "00", second: "00") == nil)
        #expect(ClockSyncModel.timeComponents(hour: "01", minute: "99", second: "00") == nil)
        #expect(ClockSyncModel.timeComponents(hour: "01", minute: "02", second: "") == nil)
    }

    @Test func customClockTimeFiltersNonNumericAndImpossibleValues() {
        #expect(ClockSyncModel.sanitizedTimeComponent("2a", maximum: "2", secondDigitMaximumWhenFirstIsMaximum: "3") == "2")
        #expect(ClockSyncModel.sanitizedTimeComponent("23", maximum: "2", secondDigitMaximumWhenFirstIsMaximum: "3") == "23")
        #expect(ClockSyncModel.sanitizedTimeComponent("29", maximum: "2", secondDigitMaximumWhenFirstIsMaximum: "3") == "2")
        #expect(ClockSyncModel.sanitizedTimeComponent("7a9", maximum: "5") == "")
        #expect(ClockSyncModel.sanitizedTimeComponent("59", maximum: "5") == "59")
    }

    @Test func clockSetPacketMatchesControlledOfficialCapture() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try #require(formatter.date(from: "2026-07-13T08:29:06-04:00"))
        var captureCalendar = Calendar(identifier: .gregorian)
        captureCalendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // Android HCI capture: raw 0x18 body after Device/SetUTC.
        #expect(ClockSyncModel.clockSetBody(date: date, calendar: captureCalendar) == Data([26, 20, 7, 13, 8, 29, 6, 1]))
    }
}
