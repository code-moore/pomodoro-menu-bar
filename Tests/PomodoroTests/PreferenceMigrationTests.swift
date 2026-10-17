import XCTest
@testable import Pomodoro

final class PreferenceMigrationTests: XCTestCase {
    func testPreservesTasksAndSettingsWithoutCopyingDevelopmentUpdaterState() throws {
        let defaults = UserDefaults.standard
        let source = "PomodoroMigrationTests.old.\(UUID())"
        let destination = "PomodoroMigrationTests.new.\(UUID())"
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        defaults.setPersistentDomain([
            "dayHistory": "saved tasks", "workMinutes": 40, "remaining": 123.5,
            "SUFeedURL": "https://example.com/appcast.xml", "updaterLastCheck": "old"
        ], forName: source)
        PreferenceMigration.migrate(defaults: defaults, destination: destination, source: source)
        let result = try XCTUnwrap(defaults.persistentDomain(forName: destination))
        XCTAssertEqual(result["dayHistory"] as? String, "saved tasks")
        XCTAssertEqual(result["workMinutes"] as? Int, 40)
        XCTAssertEqual(result["remaining"] as? Double, 123.5)
        XCTAssertNil(result["SUFeedURL"])
        XCTAssertNil(result["updaterLastCheck"])
        XCTAssertEqual(defaults.persistentDomain(forName: source)?["dayHistory"] as? String, "saved tasks")
    }

    func testExistingPreferencesWinAndMigrationDoesNotRepeat() throws {
        let defaults = UserDefaults.standard
        let source = "PomodoroMigrationTests.old.\(UUID())"
        let destination = "PomodoroMigrationTests.new.\(UUID())"
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        defaults.setPersistentDomain(["dayHistory": "old tasks", "workMinutes": 40], forName: source)
        defaults.setPersistentDomain(["dayHistory": "new tasks"], forName: destination)
        PreferenceMigration.migrate(defaults: defaults, destination: destination, source: source)
        XCTAssertEqual(defaults.persistentDomain(forName: destination)?["dayHistory"] as? String, "new tasks")
        defaults.setPersistentDomain(["newLegacyKey": "must not migrate again"], forName: source)
        PreferenceMigration.migrate(defaults: defaults, destination: destination, source: source)
        XCTAssertNil(defaults.persistentDomain(forName: destination)?["newLegacyKey"])
    }
}
