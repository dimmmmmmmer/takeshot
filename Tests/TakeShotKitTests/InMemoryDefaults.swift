import Foundation

/// A `UserDefaults` that never reaches cfprefsd.
///
/// `ControllerHarness` used to hand the controller a scratch preferences SUITE,
/// emptied around every test. A preferences domain is disk-backed and mutated
/// asynchronously, and emptying it raced with the write that sets the fixture's
/// record folder: the removal landed after the save, took it with it, and dropped
/// the cache back to whatever had last reached disk. Nothing throws when that
/// happens — `CaptureSettings.loaded` returns the PREVIOUS test's scratch folder,
/// or a default `CaptureSettings`, and a default's destinationPath is the
/// operator's real ~/Movies/TakeShot with monitorEnabled true. A controller then
/// scanned the operator's own takes and was one routing call away from playing
/// the demo source's tones out of their speakers. Both were observed under
/// coverage instrumentation, which is how CI runs this suite; `synchronize()` and
/// per-key removal each made it likelier rather than fixing it.
///
/// So: no domain at all. Everything the app stores goes through
/// `object(forKey:)` / `set(_:forKey:)` / `removeObject(forKey:)` —
/// `CaptureSettings` and the hotkey bindings as Data, `panelSide` as a String,
/// and the views' `@AppStorage`. Overriding those is enough, the store dies with
/// the test, and nothing is left behind in the operator's Preferences folder.
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

    func removeAll() { storage.removeAll() }
}
