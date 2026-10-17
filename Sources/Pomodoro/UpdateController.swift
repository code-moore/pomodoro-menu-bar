// The App Store build has no Sparkle: the store does the updating. It gets
// the empty stand-in at the bottom of this file instead.
#if !APP_STORE

import AppKit
import Foundation
import Sparkle

/// Records what Sparkle's update checks actually do.
///
/// Deliberately *not* `@MainActor`: `SPUUpdaterDelegate` is an Objective-C
/// protocol, and an actor-isolated conformance silently stops matching the
/// optional requirements — Sparkle then never calls them. This writes straight
/// to UserDefaults, which is safe from any thread.
final class UpdaterRecorder: NSObject, SPUUpdaterDelegate {
    private static let key = "updaterLastCheck"

    static var lastResult: String {
        UserDefaults.standard.string(forKey: key) ?? "no check yet"
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func record(_ message: String) {
        UserDefaults.standard.set(message, forKey: Self.key)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record("FOUND UPDATE \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        record("no update available — feed fetched and parsed cleanly")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record("ABORTED: \(error.localizedDescription)")
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            record("cycle finished with error: \(error.localizedDescription)")
        }
    }
}

/// Thin wrapper around Sparkle's standard updater.
///
/// Sparkle is only started when the build is genuinely configured for updates —
/// a real feed URL and a real EdDSA public key. Starting it against the
/// placeholder values that ship by default makes Sparkle fail during startup,
/// which the standard user driver surfaces as a "cannot be updated, contact the
/// developer" alert on every launch.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController?
    private let recorder = UpdaterRecorder()
    private let feedURL: String
    private let publicKeyPresent: Bool
    private let misconfiguration: String?
    private var diagnosticsTimer: Timer?

    override init() {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        feedURL = feed
        publicKeyPresent = !key.isEmpty

        var problems: [String] = []
        if feed.isEmpty || feed.contains("example.com") {
            problems.append("SUFeedURL is unset or still the placeholder")
        }
        if key.isEmpty {
            problems.append("SUPublicEDKey is empty")
        }
        misconfiguration = problems.isEmpty ? nil : problems.joined(separator: "; ")

        super.init()

        if misconfiguration == nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: recorder,
                userDriverDelegate: nil
            )
        }

        publishDiagnostics()

        // A check completes long after init, so republish periodically —
        // otherwise the readout stays frozen at "no check yet" and actively
        // misleads anyone debugging updates.
        if controller != nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishDiagnostics() }
            }
            RunLoop.main.add(timer, forMode: .common)
            diagnosticsTimer = timer
        }
    }

    var isConfigured: Bool { controller != nil }

    /// Refreshes the diagnostics blob. Also called on a timer so a check that
    /// completes later is reflected.
    func publishDiagnostics() {
        var lines = [
            "sparkleUpdaterStarted: \(controller != nil)",
            "feedURL: \(feedURL.isEmpty ? "(empty)" : feedURL)",
            "publicKeyPresent: \(publicKeyPresent)",
            "lastCheck: \(UpdaterRecorder.lastResult)",
        ]
        if let misconfiguration {
            lines.append("problems: \(misconfiguration)")
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: "updaterDiagnostics")
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
            return
        }

        // Assembled from what is *actually* missing, so it cannot drift out of
        // sync with the build the way a fixed paragraph does.
        var steps: [String] = []
        var step = 1
        if !publicKeyPresent {
            steps.append("""
                \(step). Create an update signing key (once):
                   ./setup-sparkle-key.sh
                """)
            step += 1
        }
        steps.append("""
            \(step). Host these two files somewhere public:
               releases/appcast.xml
               releases/Pomodoro-<version>.dmg  (or .zip)
            """)
        step += 1
        steps.append("""
            \(step). Rebuild pointed at that URL:
               APPCAST_URL=https://your.site/appcast.xml ./build.sh
            """)

        let alert = NSAlert()
        alert.messageText = "Updates aren't live yet"
        alert.informativeText = """
            This build isn't checking for updates because \
            \(misconfiguration ?? "it is not configured").

            \(steps.joined(separator: "\n\n"))
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

#else

import Combine

/// Nothing to drive: App Store builds are updated by the App Store.
@MainActor
final class UpdateController: ObservableObject {}

#endif
