import CDataChannel
import CNDI
import CSRT
import Foundation

// The bridge between the app's language switch and what the SDK bridges say
// about themselves, and the companion of `AlarmLocalization` — same reason,
// same shape, opposite direction.
//
// `AlarmLocalization` exists because CaptureCore reported a failure as English
// PROSE and the app had to read a severity off it. This exists because the
// Obj-C bridges report unavailability as English prose and the app had to show
// it. Both are the same move: the layer that KNOWS states a fact, and the layer
// that has a bundle chooses the words.
//
// What is different here, and it is the safety of the whole thing: the prose
// does not go away. A bridge is the one place in this app that can grow a
// failure mode the app layer has never heard of — a new dlopen check, a new
// SDK version test — and when that happens the app has no words for the code
// and shows the bridge's own English sentence. Never a blank row, never a
// silent switch that says nothing.

/// Why one of the SDK bridges cannot be used: the bridge's FACT, the bridge's
/// own English sentence, and the detail a code may need.
///
/// Deliberately one type for all three bridges rather than one each. They ask
/// the same question and their codes are drawn from the same four states any
/// dlopen-ed SDK can be in (see `CSRTUnavailableNotBuilt` and its siblings), so
/// a second copy of this would be a second place for the fallback rule to be
/// got wrong.
struct BridgeUnavailable: Equatable, Sendable {
    /// The stable identifier the words are keyed off, as the bridge states it
    /// — `"srt_not_built"`, `"ndi_runtime_missing"`, and so on.
    ///
    /// Optional, and the nil case is not defensive padding: it is how a caller
    /// says *I have a sentence and no fact*. `AACConverter.unavailable` is the
    /// real one — AudioToolbox is in the OS rather than a vendor drop, so there
    /// is no bridge state to name and nothing to key a translation off. nil
    /// renders the English, which is exactly the path an unrecognised code
    /// takes.
    let code: String?
    /// The bridge's own English. What a diagnostics bundle carries, and what
    /// this shows for a code this build has no words for.
    let english: String
    /// The paths the bridge's dlopen looked at. Empty for every code but
    /// `…RuntimeMissing`, and empty in a stub build, which searched nowhere.
    let searchPaths: [String]

    init(code: String?, english: String, searchPaths: [String] = []) {
        self.code = code
        self.english = english
        self.searchPaths = searchPaths
    }

    /// Built from one bridge's three answers; nil when the bridge is usable.
    ///
    /// `reason` is the single source of that truth, exactly as it was before
    /// any of this: a bridge cannot be unavailable with nothing to say, so
    /// there is no state where the app has a code and no sentence to fall back
    /// on.
    init?(reason: String?, code: String?, searchPaths: [String]) {
        guard let reason else { return nil }
        self.init(code: code, english: reason, searchPaths: searchPaths)
    }

    /// The .strings key a code is looked up under. One prefix so the whole
    /// vocabulary sorts together in both files and a translator can see at a
    /// glance that a bridge is missing one.
    static func key(for code: String) -> String { "bridge_\(code)" }

    /// What the operator reads — in their language when this build has words
    /// for the code, and the bridge's own English when it does not.
    ///
    /// The fallback is the point rather than the leftover. A bridge that grows
    /// a failure mode tomorrow is shipped by a build that has never heard of
    /// it, and the two ways that can go are a blank row or an English sentence
    /// that names what to do. `BridgeLocalizationTests` holds the second.
    var localizedText: String {
        guard let code, let words = L10n.translation(Self.key(for: code))
        else { return english }
        // Formatted on the PLACEHOLDER being there, not on the paths being
        // there, and the difference is a real one both ways round. Keyed off
        // the paths, `runtime_missing` with an empty list showed the operator a
        // literal `%@` — which is what `aSearchCodeWithNoPathsIsStillASentence`
        // caught. Formatting unconditionally instead would put a future
        // translation's bare `%` through `String(format:)` and corrupt a line
        // that never asked for an argument. A translation carrying `%@` AND a
        // stray `%` is still wrong, and nothing here can see that — it is a
        // translator's error in a string this app supplies the format for.
        guard words.contains("%@") else { return words }
        return String(format: words, searchPaths.joined(separator: ", "))
    }
}

extension BridgeUnavailable {
    /// SRT's answer, or nil when the link can be opened.
    ///
    /// Reading the bridge is what triggers its `dlopen`, so this is called when
    /// the operator asks for the feature and not before — see the note at the
    /// top of `CaptureController+SRT`.
    static var srt: BridgeUnavailable? {
        BridgeUnavailable(reason: CSRTSender.unavailableReason(),
                          code: CSRTSender.unavailableCode(),
                          searchPaths: CSRTSender.runtimeSearchPaths())
    }

    /// NDI's answer, or nil when a source can be announced.
    static var ndi: BridgeUnavailable? {
        BridgeUnavailable(reason: CNDSender.unavailableReason(),
                          code: CNDSender.unavailableCode(),
                          searchPaths: CNDSender.runtimeSearchPaths())
    }

    /// WebRTC's answer, or nil when an offer can be answered.
    static var webrtc: BridgeUnavailable? {
        BridgeUnavailable(reason: CDCPeerConnection.unavailableReason(),
                          code: CDCPeerConnection.unavailableCode(),
                          searchPaths: CDCPeerConnection.runtimeSearchPaths())
    }
}
