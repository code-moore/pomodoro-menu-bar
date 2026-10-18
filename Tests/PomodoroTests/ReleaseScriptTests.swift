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

        for (built, expected) in [("0", "old"), ("1", "new")] {
            let setup = """
                cd '\(directory.path)'
                rm -rf Pomodoro.app Pomodoro.app.previous
                mkdir -p Pomodoro.app.previous Pomodoro.app
                echo old > Pomodoro.app.previous/marker
                echo new > Pomodoro.app/marker
                APP=Pomodoro.app WAS_RUNNING=1 BUILD_OK=\(built) ICON_TEMP=""
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
}
