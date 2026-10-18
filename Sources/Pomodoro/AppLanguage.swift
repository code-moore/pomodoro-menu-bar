import Foundation

/// The language macOS picked for the app from the ones it's translated into.
enum AppLanguage {
    /// Website path segments for the app's languages. The site has pages in
    /// the same languages; anything else gets the English pages.
    static let websiteSegments: [String: String] = [
        "de": "de", "es": "es", "fil": "fil", "fr": "fr", "it": "it", "ja": "ja",
        "ko": "ko", "nl": "nl", "pt-BR": "pt-br", "sv": "sv", "zh-Hans": "zh-hans",
    ]

    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// A quietpomodoro.com page in the app's language, e.g. "early-access/".
    static func websiteURL(_ path: String, language: String = code) -> URL {
        let prefix = websiteSegments[language].map { "\($0)/" } ?? ""
        return URL(string: "https://quietpomodoro.com/\(prefix)\(path)")!
    }
}
