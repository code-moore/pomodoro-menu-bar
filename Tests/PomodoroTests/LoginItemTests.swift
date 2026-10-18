import ServiceManagement
import XCTest
@testable import Pomodoro

private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var failure: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@MainActor
final class LoginItemTests: XCTestCase {
    func testOffUntilTheUserTurnsItOn() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service, openLoginItemsSettings: {})
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.registerCalls, 0)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCalls, 1)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testReflectsChangesMadeInSystemSettings() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service, openLoginItemsSettings: {})
        XCTAssertTrue(controller.isEnabled)

        service.status = .requiresApproval
        controller.refresh()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.needsApproval)
    }

    func testTurningOnAnItemAwaitingApprovalOpensSystemSettings() {
        let service = FakeLoginItemService(status: .requiresApproval)
        var opened = 0
        let controller = LoginItemController(service: service, openLoginItemsSettings: { opened += 1 })

        controller.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 0, "registering again does nothing; approval is the user's")
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRegistrationThatNeedsApprovalOpensSystemSettings() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        var opened = 0
        let controller = LoginItemController(service: service, openLoginItemsSettings: { opened += 1 })

        controller.setEnabled(true)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(controller.needsApproval)
    }

    func testFailureIsShownAndTheSwitchKeepsTheRealState() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.failure = NSError(domain: "test", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let controller = LoginItemController(service: service, openLoginItemsSettings: {})

        controller.setEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "Operation not permitted")

        service.failure = nil
        controller.setEnabled(true)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isEnabled)
    }
}
