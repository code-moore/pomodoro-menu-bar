import XCTest

final class AppStoreScriptTests: XCTestCase {
    /// Run only the team-ID preflight, without building or accessing signing credentials.
    private func preflight(teamID: String?) throws -> (status: Int32, output: String) {
        let source = try ScriptTestSupport.source("build-appstore.sh")
        let start = try XCTUnwrap(source.range(of: "TEAM_ID=\"${TEAM_ID:-}\""))
        let end = try XCTUnwrap(source.range(of: "\nAPP_NAME=", range: start.upperBound..<source.endIndex))
        let script = String(source[start.lowerBound..<end.lowerBound])

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TEAM_ID")
        if let teamID { environment["TEAM_ID"] = teamID }
        return try ScriptTestSupport.snippet(script + "\nprintf 'accepted:%s' \"$TEAM_ID\"\n",
                                             environment: environment)
    }

    func testMissingTeamIDFailsBeforeBuild() throws {
        let result = try preflight(teamID: nil)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Set TEAM_ID"))
        XCTAssertFalse(result.output.contains("accepted:"))
    }

    func testPlaceholderAndMalformedTeamIDsFail() throws {
        for teamID in ["", "TEAM_ID", "YOUR_TEAM_ID", "ABC123DEF", "ABC123DEF45", "abc123def4", "ABC123DE 4"] {
            let result = try preflight(teamID: teamID)
            XCTAssertNotEqual(result.status, 0, teamID)
            XCTAssertTrue(result.output.contains("Set TEAM_ID"), teamID)
            XCTAssertFalse(result.output.contains("accepted:"), teamID)
        }
    }

    func testExplicitTeamIDIsPreserved() throws {
        let result = try preflight(teamID: "ABC123DEF4")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "accepted:ABC123DEF4")
    }
}
