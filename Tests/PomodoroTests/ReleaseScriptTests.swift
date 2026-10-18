import XCTest

final class ReleaseScriptTests: XCTestCase {
    private func source(_ path: String = "release.sh") throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func runResult(_ script: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\n" + script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Execute only the script's appcast decision, never build, sign or package.
    private func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\n" + script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
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
        let rejected = try runResult(setup + "codesign() { return 1; }\n" + verification)
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertFalse(rejected.output.contains("==> Built"))
        XCTAssertEqual(try run(setup + "codesign() { return 0; }\n" + verification), 0)
    }

    func testEmptyToolDiscoveryIsAnError() throws {
        let script = try source()
        let start = try XCTUnwrap(script.range(of: "if [ -z \"$GEN_APPCAST\" ]; then"))
        let end = try XCTUnwrap(script.range(of: "\nfi", range: start.upperBound..<script.endIndex))
        let decision = String(script[start.lowerBound..<end.upperBound])
        XCTAssertNotEqual(try run("GEN_APPCAST=''\n" + decision), 0)
    }

    func testReleaseRejectsUnsafeInputsWithoutChangingSourceVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("release.sh").path] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0)
            XCTAssertEqual(try Data(contentsOf: plist), original)
        }
    }
}
