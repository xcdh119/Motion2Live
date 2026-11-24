import Foundation

enum L10n {
    static var isEnglish: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
    }

    static var appName: String { isEnglish ? "Lumina" : "光影间" }

    static var tagline: String {
        isEnglish
            ? "Turn OPPO / vivo motion photos into iPhone Live Photos"
            : "把 OPPO / vivo 的动态照片变成 iPhone 实况"
    }

    static var settings: String { isEnglish ? "Settings" : "设置" }
    static var conversionLog: String { isEnglish ? "Conversion Log" : "转换日志" }
    static var history: String { isEnglish ? "History" : "转换历史" }
    static var about: String { isEnglish ? "About Lumina" : "关于光影间" }
}
