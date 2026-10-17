import Foundation

/// Keep local users' tasks and settings when adopting the distribution ID.
enum PreferenceMigration {
    static func migrate(defaults: UserDefaults = .standard,
                        destination: String = "com.codemoore.pomodoro.menubar",
                        source: String = "local.pomodoro.menubar") {
        let marker = "migratedDevelopmentPreferences"
        var current = defaults.persistentDomain(forName: destination) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: source) ?? [:]
        for (key, value) in legacy where current[key] == nil {
            // Old feed overrides and updater state must not follow the app.
            guard !key.hasPrefix("SU"), !key.hasPrefix("NS"),
                  !key.hasPrefix("updater"), key != "diagnostics" else { continue }
            current[key] = value
        }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: destination)
    }
}
