import EventKit
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

    func testFreeTimedEventsAreLeftOutButAllDayOnesStay() {
        XCTAssertTrue(CalendarService.isShown(canceled: false, declined: false, free: false, banner: false))
        XCTAssertFalse(CalendarService.isShown(canceled: false, declined: false, free: true, banner: false),
                       "Free time doesn't block work")
        // Calendar marks new all-day events Free. They never block work, and
        // still show as banners, as they did before.
        XCTAssertTrue(CalendarService.isShown(canceled: false, declined: false, free: true, banner: true))
        XCTAssertFalse(CalendarService.isShown(canceled: true, declined: false, free: false, banner: true))
        XCTAssertFalse(CalendarService.isShown(canceled: false, declined: true, free: false, banner: true))
    }

    func testAllDayAndWholeDayEventsAreBanners() {
        let store = EKEventStore()
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let dayEnd = dayStart.addingTimeInterval(86400)
        func event(allDay: Bool = false, from start: Date, to end: Date) -> EKEvent {
            let event = EKEvent(eventStore: store)
            event.isAllDay = allDay
            event.startDate = start
            event.endDate = end
            return event
        }
        let morning = dayStart.addingTimeInterval(9 * 3600)
        XCTAssertFalse(CalendarService.isBanner(event(from: morning, to: morning.addingTimeInterval(1800)),
                                                dayStart: dayStart, dayEnd: dayEnd))
        XCTAssertTrue(CalendarService.isBanner(event(allDay: true, from: dayStart, to: dayEnd),
                                               dayStart: dayStart, dayEnd: dayEnd))
        XCTAssertTrue(CalendarService.isBanner(event(from: dayStart.addingTimeInterval(-3600), to: dayEnd.addingTimeInterval(3600)),
                                               dayStart: dayStart, dayEnd: dayEnd), "A timed event covering the day")
    }
}
