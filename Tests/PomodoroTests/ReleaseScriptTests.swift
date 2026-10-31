import XCTest

final class ReleaseScriptTests: XCTestCase {
    private func source(_ path: String = "release.sh") throws -> String {
        try ScriptTestSupport.source(path)
    }

    /// Execute only a fragment of a script, never build, sign or package.
    private func run(_ script: String) throws -> Int32 {
        try ScriptTestSupport.snippet(script).status
    }

    func testGeneratorFailureIsNonzeroAndSuccessStaysSuccessful() throws {
        let script = try source()
        let start = try XCTUnwrap(script.range(of: "if \"$GEN_APPCAST\""))
        let end = try XCTUnwrap(script.range(of: "\nfi", range: start.upperBound..<script.endIndex))
        let decision = String(script[start.lowerBound..<end.upperBound])
        let setup = """
            KEY_ARGS=(--account test)
            STAGING=/unused
            DOWNLOAD_URL_PREFIX=https://downloads.test/
            OUT=Pomodoro-test.zip
            EMBEDDED_KEY=test
            BUILD_NUMBER=2
            VERSION=1.2
            PYTHON=python3
            python3() { return 0; }

            """
        XCTAssertNotEqual(try run(setup + "GEN_APPCAST=/usr/bin/false\n" + decision), 0)
        XCTAssertEqual(try run(setup + "GEN_APPCAST=/usr/bin/true\n" + decision), 0)
        XCTAssertNotEqual(try run(setup + "python3() { return 1; }\nGEN_APPCAST=/usr/bin/true\n" + decision), 0)
    }

    func testBuildFailsWhenCodeSignatureVerificationFails() throws {
        let script = try source("build.sh")
        let start = try XCTUnwrap(script.range(of: "echo \"==> Verifying signature\""))
        let verification = String(script[start.lowerBound...])
        let setup = "APP=Pomodoro.app\nWAS_RUNNING=0\n"
        let rejected = try ScriptTestSupport.snippet(setup + "codesign() { return 1; }\n" + verification)
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertFalse(rejected.output.contains("==> Built"))
        XCTAssertEqual(try run(setup + "codesign() { return 0; }\n" + verification), 0)
    }

    func testFailedBuildRestoresAndReopensThePreviousApp() throws {
        let script = try source("build.sh")
        let start = try XCTUnwrap(script.range(of: "cleanup() {"))
        let end = try XCTUnwrap(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let cleanup = String(script[start.lowerBound..<end.upperBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A bundle left behind by a killed run must not replace a good one
        // when this run fails before setting the current one aside.
        for (built, moved, expected) in [("0", "1", "old"), ("1", "1", "new"), ("0", "0", "new")] {
            let setup = """
                cd '\(directory.path)'
                rm -rf Pomodoro.app Pomodoro.app.previous
                mkdir -p Pomodoro.app.previous Pomodoro.app
                echo old > Pomodoro.app.previous/marker
                echo new > Pomodoro.app/marker
                APP=Pomodoro.app WAS_RUNNING=1 BUILD_OK=\(built) MOVED_PREVIOUS=\(moved) ICON_TEMP=""
                open() { echo "opened $1"; }

                """
            let result = try ScriptTestSupport.snippet(setup + cleanup + "cleanup\ncat Pomodoro.app/marker\n")
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.hasSuffix("\(expected)\n"), result.output)
            XCTAssertEqual(result.output.contains("opened Pomodoro.app"), built == "0", result.output)
        }
    }

    func testEmptyToolDiscoveryIsAnError() throws {
        let script = try source()
        let start = try XCTUnwrap(script.range(of: "if [ -z \"$GEN_APPCAST\" ]; then"))
        let end = try XCTUnwrap(script.range(of: "\nfi", range: start.upperBound..<script.endIndex))
        let decision = String(script[start.lowerBound..<end.upperBound])
        XCTAssertNotEqual(try run("GEN_APPCAST=''\n" + decision), 0)
    }

    func testReleaseRejectsUnsafeInputsWithoutChangingSourceVersion() throws {
        let root = ScriptTestSupport.root
        let plist = root.appendingPathComponent("Resources/Info.plist")
        let original = try Data(contentsOf: plist)
        for (arguments, overrides) in [
            (["../../bad"], [:]),
            (["1.2"], ["NOTARIZE": "0"]),
            (["1.2"], ["APPCAST_URL": "http://quietpomodoro.com/appcast.xml"]),
            (["1.2"], ["APPCAST_URL": "https://example.com/appcast.xml"]),
            (["1.2"], ["APPCAST_URL": "https://quietpomodoro.com/appcast.xml?token=secret"]),
            (["1.2"], ["BUILD_NUMBER": "not-a-number"])
        ] {
            let result = try ScriptTestSupport.bash(
                [root.appendingPathComponent("release.sh").path] + arguments,
                environment: ProcessInfo.processInfo.environment.merging(overrides) { _, new in new })
            XCTAssertNotEqual(result.status, 0)
            XCTAssertEqual(try Data(contentsOf: plist), original)
        }
    }

    func testOnlyReleasesDefaultToTheOfficialUpdateFeed() throws {
        let script = try source("build.sh")
        let chooseStart = try XCTUnwrap(script.range(of: "APPCAST_URL=\"${APPCAST_URL:-}\""))
        let chooseEnd = try XCTUnwrap(script.range(of: "\nfi", range: chooseStart.upperBound..<script.endIndex))
        let applyStart = try XCTUnwrap(script.range(of: "if [ -n \"$APPCAST_URL\" ]; then"))
        let applyEnd = try XCTUnwrap(script.range(of: "\nfi", range: applyStart.upperBound..<script.endIndex))
        let choose = String(script[chooseStart.lowerBound..<chooseEnd.upperBound])
        let apply = String(script[applyStart.lowerBound..<applyEnd.upperBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let official = "https://quietpomodoro.com/downloads/mac/appcast.xml"
        let custom = "https://updates.test/appcast.xml"
        for (release, url, expected) in [
            ("0", "", "Does Not Exist"), ("1", "", official), ("0", custom, custom), ("1", custom, custom)
        ] {
            let result = try ScriptTestSupport.snippet("""
                cd '\(ScriptTestSupport.root.path)'
                RELEASE_BUILD=\(release) APPCAST_URL='\(url)' APP='\(directory.path)/Test.app'
                mkdir -p "$APP/Contents"
                cp Resources/Info.plist "$APP/Contents/Info.plist"
                \(choose)
                \(apply)
                /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" || true
                """)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains(expected), result.output)
        }
    }

    func testNewestTagComparesVersionsAndIgnoresOtherTags() throws {
        let script = try source("Tools/ci-publish.sh")
        let start = try XCTUnwrap(script.range(of: "newest_tag() {"))
        let end = try XCTUnwrap(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let result = try ScriptTestSupport.snippet("""
            SOURCE=test GH_SOURCE_TOKEN=test
            gh() { printf 'refs/tags/%s\\n' v1.9.0 v1.10.0 v1.7.5 v2-beta; }
            \(function)
            newest_tag
            """)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "v1.10.0\n")
    }
}
