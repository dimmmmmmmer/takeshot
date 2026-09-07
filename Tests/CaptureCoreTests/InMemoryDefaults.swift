import Foundation

/// A `UserDefaults` that keeps everything in memory and touches no domain.
///
/// **A copy of `TakeShotKitTests.InMemoryDefaults`, deliberately.** The two
/// test targets cannot share code, and this file follows the rule the rest of
/// the suites follow when that happens: one name per idea, stated twice, rather
/// than a third target nobody reads.
///
/// Why it exists at all: `UserDefaults(suiteName:)` writes a plist, and no
/// teardown gets rid of it. Removing the domain empties it and cfprefsd writes
/// the emptiness back on its own schedule — after the delete, whatever order
/// the teardown uses. 7,237 of them had collected in the development machine's
/// ~/Library/Preferences, one per test case per run, every one an empty
/// dictionary Preferences scans on every launch of every app.
///
/// Everything these suites store goes through `object(forKey:)` /
/// `set(_:forKey:)` / `removeObject(forKey:)` — `CaptureSettings` as Data —
/// and `dictionaryRepresentation()`, which the superclass would otherwise
/// answer for the whole global domain.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] { storage }

    // The typed setters are separate Obj-C selectors; route them through the
    // one override above rather than trusting them to call it.
    override func set(_ value: Int, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    override func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func integer(forKey defaultName: String) -> Int {
        storage[defaultName] as? Int ?? 0
    }

    override func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    override func double(forKey defaultName: String) -> Double {
        storage[defaultName] as? Double ?? 0
    }
}
