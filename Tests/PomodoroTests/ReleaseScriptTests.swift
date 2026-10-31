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

    func testSourceReleasePublishesOnceToTheSourceRepository() throws {
        let script = try source("Tools/ci-publish.sh")
        let start = try XCTUnwrap(script.range(of: "publish_source_release() {"))
        let end = try XCTUnwrap(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func run(whenViewed view: String) throws -> (status: Int32, output: String) {
            try ScriptTestSupport.snippet("""
                cd '\(directory.path)'
                mkdir -p releases
                rm -f calls.txt
                echo archive > releases/Pomodoro-1.7.6.dmg
                SOURCE=owner/app TAG=v1.7.6 VERSION=1.7.6 DMG=Pomodoro-1.7.6.dmg GITHUB_SHA=abc
                sha256sum() { shasum -a 256 "$@"; }
                newest_tag() { echo v1.7.6; }
                gh() {
                  echo "$*" >> calls.txt
                  case "$1 $2" in
                    'release view') \(view) ;;
                    'release download') cp releases/SHA256SUMS.txt "${@: -1}/" ;;
                  esac
                }
                \(function)
                publish_source_release
                cat calls.txt
                """)
        }

        let new = try run(whenViewed: "return 1")
        XCTAssertEqual(new.status, 0, new.output)
        XCTAssertTrue(new.output.contains("release create v1.7.6 -R owner/app --target abc --draft"), new.output)
        XCTAssertTrue(new.output.contains("release edit v1.7.6 -R owner/app --draft=false --latest=true"), new.output)

        // A retry after a later step failed must not touch the public release.
        let published = try run(whenViewed: "echo '{\"isDraft\": false}'")
        XCTAssertEqual(published.status, 0, published.output)
        XCTAssertFalse(published.output.contains("release upload"), published.output)
    }

    func testWebsitePublicationResumesItsPRWithoutPushingMasterOrRewritingHistory() throws {
        let script = try source("Tools/ci-publish.sh")
        let start = try XCTUnwrap(script.range(of: "export GH_TOKEN=\"$GH_WEBSITE_TOKEN\""))
        let publish = String(script[start.lowerBound...])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try ScriptTestSupport.snippet("""
            cd '\(directory.path)'
            git init --quiet --bare --initial-branch=master remote.git
            git init --quiet --initial-branch=master seed
            git -C seed config user.name Test
            git -C seed config user.email test@example.com
            mkdir -p seed/site/dist/downloads/mac seed/site/scripts releases
            echo old-feed > seed/site/dist/downloads/mac/appcast.xml
            echo "export const MAC_VERSION = '1.7.5';" > seed/site/scripts/mac-release.mjs
            git -C seed add .
            git -C seed commit --quiet -m Initial
            git -C seed remote add origin "$PWD/remote.git"
            git -C seed push --quiet origin master
            echo verified-archive > releases/Pomodoro-1.7.6.dmg
            echo verified-checksum > releases/Pomodoro-1.7.6.dmg.sha256
            echo signed-feed > releases/appcast.xml
            """)
        XCTAssertEqual(fixture.status, 0, fixture.output)

        // Only GitHub and npm are simulated. Real shallow clones, commits,
        // branch pushes and merges exercise the failed-job retry path.
        let setup = """
            cd '\(directory.path)'
            REMOTE="$PWD/remote.git" LOG="$PWD/calls.log" PR_STATE="$PWD/open-pr"
            export GITHUB_STEP_SUMMARY="$PWD/summary"
            GH_WEBSITE_TOKEN=website-test WEBSITE=test/website
            VERSION=1.7.6 TAG=v1.7.6 DMG=Pomodoro-1.7.6.dmg GITHUB_SHA=source-test
            git() {
              local argument
              for argument in "$@"; do
                if [ "$argument" = push ]; then
                  echo "git $*" >> "$LOG"
                  [[ "${!#}" = HEAD:refs/heads/release/pomodoro-v1.7.6 ]]
                  [[ " $* " != *' --force'* ]]
                fi
              done
              command git "$@"
            }
            npm() { echo "npm $*" >> "$LOG"; }
            gh() {
              test "$GH_TOKEN" = website-test
              echo "gh $*" >> "$LOG"
              case "$1 $2" in
                'repo clone') command git clone --quiet --depth 1 --branch master "file://$REMOTE" website ;;
                'pr list') if [ -f "$PR_STATE" ]; then cat "$PR_STATE"; fi ;;
                'pr create')
                  test -s releases/website-pr.md
                  echo 42 > "$PR_STATE"
                  echo https://github.com/test/website/pull/42
                  ;;
                'pr merge')
                  test "$3" = 42
                  [[ " $* " = *' --merge '* ]]
                  [[ " $* " = *' --author-email 59375712+msmfa@users.noreply.github.com '* ]]
                  [[ " $* " != *' --admin '* ]]
                  local head
                  head="$(command git -C website rev-parse HEAD)"
                  [[ "$*" = *"--match-head-commit $head" ]]
                  if [ "$REJECT_MERGE" = 1 ]; then return 1; fi
                  command git -C "$REMOTE" update-ref refs/heads/master "$head"
                  rm "$PR_STATE"
                  ;;
                *) return 1 ;;
              esac
            }

            """

        let rejected = try ScriptTestSupport.snippet(setup + "REJECT_MERGE=1\n" + publish)
        XCTAssertNotEqual(rejected.status, 0, rejected.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary").path))

        // Master advances while the published branch and open PR remain.
        let advance = try ScriptTestSupport.snippet("""
            cd '\(directory.path)'
            git --git-dir=remote.git show master:site/scripts/mac-release.mjs | grep "1.7.5"
            git --git-dir=remote.git rev-parse refs/heads/release/pomodoro-v1.7.6 > first-head
            echo keep-this-change > seed/unrelated.txt
            git -C seed add unrelated.txt
            git -C seed commit --quiet -m 'Unrelated website change'
            git -C seed push --quiet origin master
            rm -rf website
            """)
        XCTAssertEqual(advance.status, 0, advance.output)

        let resumed = try ScriptTestSupport.snippet(setup + "REJECT_MERGE=0\n" + publish)
        XCTAssertEqual(resumed.status, 0, resumed.output)
        let verify = try ScriptTestSupport.snippet("""
            cd '\(directory.path)'
            git --git-dir=remote.git merge-base --is-ancestor "$(cat first-head)" master
            git --git-dir=remote.git show master:site/scripts/mac-release.mjs | grep "1.7.6"
            git --git-dir=remote.git show master:unrelated.txt | grep keep-this-change
            git --git-dir=remote.git show master:site/dist/downloads/mac/Pomodoro-1.7.6.dmg | cmp - releases/Pomodoro-1.7.6.dmg
            rm -rf website
            """)
        XCTAssertEqual(verify.status, 0, verify.output)

        let alreadyPublished = try ScriptTestSupport.snippet(setup + "REJECT_MERGE=0\n" + publish)
        XCTAssertEqual(alreadyPublished.status, 0, alreadyPublished.output)
        let calls = try String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(calls.filter { $0.hasPrefix("gh pr create ") }.count, 1)
        XCTAssertEqual(calls.filter { $0.hasPrefix("gh pr merge ") }.count, 2)
        XCTAssertEqual(calls.filter { $0.hasPrefix("git ") }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "npm run build:ci" }.count, 3)
    }
}
