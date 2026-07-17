import Foundation

/// Язык интерфейса. Приоритетный (и базовый для новых строк) — английский.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }
}

/// Локализация с переключением языка на лету: строки берутся из .lproj-бандла
/// выбранного языка, минуя системную настройку.
enum L10n {
    private static var bundle: Bundle = .module

    static func apply(_ language: AppLanguage) {
        switch language {
        case .system:
            bundle = .module
        case .english, .russian:
            if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
               let languageBundle = Bundle(path: path) {
                bundle = languageBundle
            } else {
                bundle = .module
            }
        }
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}

/// Короткий хелпер для вьюх.
func L(_ key: String) -> String {
    L10n.string(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: arguments)
}
