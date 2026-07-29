import Foundation
import os

/// UI language. English is the preferred (and base) language for new strings.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }
}

/// Localization with on-the-fly language switching: strings come from the
/// selected language's .lproj bundle, bypassing the system setting.
enum L10n {
    /// The bundle is swapped on the main thread when the operator changes the
    /// language, and read from any thread that formats a message — the offload
    /// worker reports its progress from its own queue, and error toasts are
    /// built wherever the failure happened. As a plain `static var` that is a
    /// data race: ThreadSanitizer flags it, and a torn read of the reference
    /// is a crash on a machine whose timing differs from the one it ran on.
    private static let state = OSAllocatedUnfairLock(initialState: Bundle.module)

    /// Copied out under the lock; the string lookup itself runs outside it.
    private static var bundle: Bundle {
        state.withLock { $0 }
    }

    static func apply(_ language: AppLanguage) {
        let selected: Bundle
        switch language {
        case .system:
            selected = .module
        case .english, .russian:
            if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
               let languageBundle = Bundle(path: path) {
                selected = languageBundle
            } else {
                selected = .module
            }
        }
        state.withLock { $0 = selected }
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}

/// Short helper for views.
func L(_ key: String) -> String {
    L10n.string(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: arguments)
}
