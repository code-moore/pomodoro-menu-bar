import XCTest

/// The translations ship complete: every string in every language, with the
/// English placeholders, and the bundle declares the languages it has.
final class LocalizationTests: XCTestCase {
    private let catalogs = ["Resources/Localizable.xcstrings", "Resources/InfoPlist.xcstrings"]

    private func check(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let script = ScriptTestSupport.root.appendingPathComponent("Tools/check-localizations.py").path
        let quoted = ([script] + arguments).map { "'\($0)'" }.joined(separator: " ")
        return try ScriptTestSupport.snippet("cd '\(ScriptTestSupport.root.path)'\n/usr/bin/python3 \(quoted)")
    }

    func testEveryStringIsTranslatedIntoEveryLanguage() throws {
        let result = try check(catalogs)
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testInfoPlistDeclaresTheTranslatedLanguages() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: ScriptTestSupport.root.appendingPathComponent("Resources/Info.plist")))
        let declared = try XCTUnwrap(plist["CFBundleLocalizations"] as? [String])
        let data = try Data(contentsOf: ScriptTestSupport.root.appendingPathComponent(catalogs[0]))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let translated = strings.values.reduce(into: Set<String>()) { languages, entry in
            if let localizations = entry["localizations"] as? [String: Any] { languages.formUnion(localizations.keys) }
        }
        XCTAssertEqual(Set(declared), translated.union(["en"]))
    }

    func testBothBuildsCompileTheCatalogsIntoTheApp() throws {
        for script in ["build.sh", "build-appstore.sh"] {
            let source = try ScriptTestSupport.source(script)
            for catalog in catalogs {
                XCTAssertTrue(source.contains(catalog), "\(script) doesn't compile \(catalog)")
            }
            XCTAssertTrue(source.contains("xcstringstool compile"), script)
            XCTAssertTrue(source.contains("Tools/check-release-localizations.sh"), "\(script) doesn't check the translations")
        }
    }

    func testCheckerRejectsIncompleteOrDriftedCatalogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let languages = ["de", "es", "fil", "fr", "it", "ja", "ko", "nl", "pt-BR", "sv", "zh-Hans"]

        func catalog(_ value: (String) -> String) -> [String: Any] {
            let localizations = Dictionary(uniqueKeysWithValues: languages.map {
                ($0, ["stringUnit": ["state": "translated", "value": value($0)]])
            })
            return ["sourceLanguage": "en", "version": "1.0",
                    "strings": ["Finish %@": ["localizations": localizations]]]
        }
        func run(_ catalog: [String: Any], code keys: [String] = ["Finish %@"],
                 options: [String] = []) throws -> (status: Int32, output: String) {
            let path = directory.appendingPathComponent("Localizable.xcstrings")
            try JSONSerialization.data(withJSONObject: catalog).write(to: path)
            let entries = keys.map { ["key": $0, "comment": ""] }
            try JSONSerialization.data(withJSONObject: ["tables": ["Localizable": entries]])
                .write(to: directory.appendingPathComponent("App.stringsdata"))
            return try check(["--stringsdata", directory.path] + options + [path.path])
        }

        XCTAssertEqual(try run(catalog { "\($0) %@" }).status, 0)

        // The App Store build leaves some strings out, but must still have
        // every string it does use.
        var full = catalog { "\($0) %@" }
        var strings = full["strings"] as! [String: [String: Any]]
        strings["Update to %@"] = strings["Finish %@"]
        full["strings"] = strings
        XCTAssertEqual(try run(full, options: ["--allow-unused"]).status, 0)
        XCTAssertNotEqual(try run(full).status, 0)
        XCTAssertNotEqual(try run(full, code: ["Finish %@", "Start"], options: ["--allow-unused"]).status, 0)

        let cases: [(String, [String: Any], [String])] = [
            ("dropped placeholder", catalog { $0 == "ja" ? "終了" : "\($0) %@" }, ["Finish %@"]),
            ("em dash", catalog { $0 == "fr" ? "Fin \u{2014} %@" : "\($0) %@" }, ["Finish %@"]),
            ("missing language", {
                var c = catalog { "\($0) %@" }
                var strings = c["strings"] as! [String: [String: Any]]
                var localizations = strings["Finish %@"]!["localizations"] as! [String: Any]
                localizations["sv"] = nil
                strings["Finish %@"]!["localizations"] = localizations
                c["strings"] = strings
                return c
            }(), ["Finish %@"]),
            ("new string in the code", catalog { "\($0) %@" }, ["Finish %@", "Start"]),
            ("stale string", catalog { "\($0) %@" }, ["Start"]),
        ]
        for (name, bad, keys) in cases {
            let result = try run(bad, code: keys)
            XCTAssertNotEqual(result.status, 0, "\(name) passed: \(result.output)")
            XCTAssertTrue(result.output.contains("ERROR"), name)
        }
    }
}
