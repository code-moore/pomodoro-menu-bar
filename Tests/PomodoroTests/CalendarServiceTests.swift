import XCTest
@testable import Pomodoro

final class CalendarServiceTests: XCTestCase {
    func testFallbackIDIsStableAndDoesNotContainTheTitle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = CalendarService.fallbackID(title: "Private meeting title", start: start,
                                            end: start.addingTimeInterval(1800), calendar: "cal")
        XCTAssertEqual(id, CalendarService.fallbackID(title: "Private meeting title", start: start,
                                                      end: start.addingTimeInterval(1800), calendar: "cal"))
        XCTAssertFalse(id.contains("Private"))
        XCTAssertNotEqual(id, CalendarService.fallbackID(title: "Other", start: start,
                                                         end: start.addingTimeInterval(1800), calendar: "cal"))
    }
}
