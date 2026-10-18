import Foundation

/// Runs pieces of the repository's shell scripts, never a whole build, signing
/// step or anything that needs credentials.
enum ScriptTestSupport {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Output is drained before waiting, so a chatty script can't fill the
    /// pipe and hang the test.
    static func bash(_ arguments: [String],
                     environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A script fragment, under the same strict mode the scripts use.
    static func snippet(_ script: String,
                        environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        try bash(["-c", "set -euo pipefail\n" + script], environment: environment)
    }
}
