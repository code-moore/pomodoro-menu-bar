import XCTest
@testable import PomodoroCore

final class DurationInputTests: XCTestCase {

    // MARK: - Hours

    func testFractionalHoursAreUnderstood() {
        // The regression: the "." used to be dropped, making this 15 hours.
        XCTAssertEqual(DurationInput.minutes(in: "1.5", unit: .hours), 90)
        XCTAssertEqual(DurationInput.minutes(in: "1,5", unit: .hours), 90)
        XCTAssertEqual(DurationInput.minutes(in: "0.25", unit: .hours), 15)
    }

    func testWholeHours() {
        XCTAssertEqual(DurationInput.minutes(in: "2", unit: .hours), 120)
        XCTAssertEqual(DurationInput.minutes(in: " 1 ", unit: .hours), 60)
    }

    func testHoursRejectAnythingThatIsNotAPlainNumber() {
        for text in ["abc", "1.5.2", "1:30", "-1", "1e3", "inf", "nan", "."] {
            XCTAssertNil(DurationInput.minutes(in: text, unit: .hours), text)
        }
    }

    // MARK: - Minutes

    func testWholeMinutes() {
        XCTAssertEqual(DurationInput.minutes(in: "25", unit: .minutes), 25)
        XCTAssertEqual(DurationInput.minutes(in: "0", unit: .minutes), 0)
    }

    func testMinutesRejectFractionsAndText() {
        for text in ["2.5", "abc", "-5", "1,5"] {
            XCTAssertNil(DurationInput.minutes(in: text, unit: .minutes), text)
        }
    }

    // MARK: - Total

    func testTotalAddsBothBoxes() {
        XCTAssertEqual(DurationInput.total(hours: "1", minutes: "30"), 90)
        XCTAssertEqual(DurationInput.total(hours: "1.5", minutes: ""), 90)
        XCTAssertEqual(DurationInput.total(hours: "", minutes: "40"), 40)
    }

    func testTotalIsNilWhenEitherBoxIsNotANumber() {
        XCTAssertNil(DurationInput.total(hours: "x", minutes: "30"))
        XCTAssertNil(DurationInput.total(hours: "1", minutes: "2.5"))
    }

    func testTotalIsNilWhenThereIsNoTimeAtAll() {
        XCTAssertNil(DurationInput.total(hours: "", minutes: ""))
        XCTAssertNil(DurationInput.total(hours: "0", minutes: "0"))
    }

    func testOversizedNumbersAreRejectedWithoutOverflow() {
        XCTAssertNil(DurationInput.minutes(in: "999999999999999999", unit: .hours))
        XCTAssertNil(DurationInput.minutes(in: String(repeating: "9", count: 400), unit: .hours))
        XCTAssertNil(DurationInput.total(hours: "1", minutes: String(Int.max)))
        XCTAssertEqual(DurationInput.total(hours: "", minutes: String(Int.max)), Int.max)
    }

    // MARK: - Meeting rows

    func testMeetingBlockUsesItsPublishedID() {
        let meeting = Meeting(
            id: "m1", title: "Sync",
            start: Date(timeIntervalSince1970: 3_600), end: Date(timeIntervalSince1970: 5_400)
        )
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [meeting], dayStart: Date(timeIntervalSince1970: 0),
            settings: Scheduler.Settings(
                workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, pomodorosBeforeLongBreak: 4
            )
        )
        // The panel finds a meeting's row by this id to put the orange bar on it.
        XCTAssertEqual(blocks.first { $0.isMeeting }?.id, Scheduler.blockID(for: meeting))
    }
}
