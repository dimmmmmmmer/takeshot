import Foundation
import Testing

@testable import TakeShotKit

/// Where a control's enabling condition is allowed to live.
///
/// **The finding this exists for.** A condition copied per surface is this
/// codebase's most productive source of bugs, measured on its own history:
/// add-marker had five surfaces, three rules between them and two of those
/// disagreed; the LUT switches had four surfaces, three rules, one disagreed.
/// And on the other side of the same audit, every site that already named its
/// rule ONCE — `canChangeRecordingFormat`, `canDimMonitoring`,
/// `showsCompareSplit`, `showsWipeHandle` — had no divergence at all. Not one.
///
/// So the rule is about WHERE, not about what: the argument of every
/// `.disabled(` under `Sources/TakeShotKit` is a single `controller.<name>`,
/// optionally negated, and nothing else. No `&&`, no `||`, no `==`, no
/// `.isEmpty`, no `contains { }`, no local `idle` — because each of those is a
/// condition, and a condition written at a surface is a condition the next
/// surface will be written slightly differently.
///
/// The negation is allowed because `!` reverses a rule without restating it; a
/// second term does not. The receiver has to be `controller` because that is
/// where app state lives: a run's own model (`offload`, `dailies`, `verify`) is
/// reached THROUGH the controller, in the domain extension that owns it, so the
/// sheet, the menu item and the takes-panel strip cannot end up with three
/// spellings of "is it going" — which is exactly what they had.
///
/// Everything this flagged was a chore rather than a behaviour change: the
/// condition moves onto `CaptureController`, keeping its meaning, and the site
/// asks for it by name. What it is NOT is a style rule — a name is the only
/// thing several surfaces can share.
struct ViewDisabledRuleTests {
    /// A site the rule cannot reach, and why not.
    ///
    /// Every entry is asserted to still exist, so an exception that stops being
    /// needed fails here instead of quietly widening the rule for everybody.
    struct Exception {
        let file: String
        let argument: String
        let reason: String
    }

    /// The two of them.
    ///
    /// Both are the same shape and it is the one shape a property cannot have:
    /// a predicate over the CONTROL's own arguments rather than over app state.
    /// A stepper arrow exists per field and per direction, a reset arrow per
    /// row; there is nothing for a parameterless `controller.something` to be.
    /// Both rules are still named exactly once — in `SlateStep` and on
    /// `HotkeyEditorModel` — which is the thing the rule is actually for.
    static let exceptions: [Exception] = [
        Exception(
            file: "SlateFields.swift",
            argument: "!SlateStep.canStep(text.wrappedValue, by: delta)",
            reason: "whether THIS field's text has a next value in THIS"
                + " direction — a question about the two arguments the arrow"
                + " was built with, answered once in SlateStep.canStep"),
        Exception(
            file: "HotkeyEditorView.swift",
            argument: "!model.isCustomized(action)",
            reason: "whether THIS row's action still holds its default"
                + " binding — answered once on HotkeyEditorModel, which owns"
                + " the bindings; the controller has no opinion about them"),
    ]

    /// One `.disabled(` in the tree.
    struct Site {
        let file: String
        let argument: String
    }

    /// `controller.name` or `!controller.name`, and nothing else.
    private func namesOneRule(_ argument: String) -> Bool {
        let body: String = argument.hasPrefix("!")
            ? String(argument.dropFirst()) : argument
        guard body.hasPrefix("controller.") else { return false }
        let name: String = String(body.dropFirst("controller.".count))
        guard let first: Character = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The file with its comments blanked out, so a `.disabled(` written ABOUT
    /// this rule in a doc comment is not read as a violation of it.
    private func code(of text: String) -> String {
        var stripped: [String] = []
        for line: String in text.components(separatedBy: "\n") {
            if let comment: Range<String.Index> = line.range(of: "//") {
                stripped.append(String(line[line.startIndex..<comment.lowerBound]))
            } else {
                stripped.append(line)
            }
        }
        return stripped.joined(separator: "\n")
    }

    /// The argument of the `.disabled(` starting at `start`, by paren balance —
    /// so a multi-line condition is read whole rather than truncated into
    /// something that happens to look compliant.
    private func argument(in text: String,
                          after start: String.Index) -> String? {
        var depth: Int = 0
        var collected: String = ""
        var index: String.Index = start
        while index < text.endIndex {
            let character: Character = text[index]
            if character == "(" {
                depth += 1
                if depth == 1 {
                    index = text.index(after: index)
                    continue
                }
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return collected.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            collected.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    /// Every `.disabled(` under `Sources/TakeShotKit`, argument in hand.
    private func sites() throws -> [Site] {
        let root: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        var isDirectory = ObjCBool(false)
        try #require(FileManager.default.fileExists(atPath: root.path,
                                                    isDirectory: &isDirectory),
                     "the TakeShotKit sources were not where this test looked")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil),
                                  "the source tree could not be walked")
        var found: [Site] = []
        var files: Int = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            guard let raw: String = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let text: String = code(of: raw)
            var search: Range<String.Index>? = text.range(of: ".disabled(")
            while let hit: Range<String.Index> = search {
                // The open paren is the last character of the match.
                let open: String.Index = text.index(before: hit.upperBound)
                if let value: String = argument(in: text, after: open) {
                    found.append(Site(file: url.lastPathComponent,
                                      argument: value))
                }
                search = text.range(of: ".disabled(",
                                    range: hit.upperBound..<text.endIndex)
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        try #require(found.count > 40,
                     "the walk found almost no .disabled( sites, so a green run here would mean nothing")
        return found
    }

    /// The rule itself.
    @Test func everyDisabledSiteNamesItsRuleOnTheController() throws {
        let all: [Site] = try sites()
        let offenders: [String] = all
            .filter { site in
                !namesOneRule(site.argument)
                    && !Self.exceptions.contains {
                        $0.file == site.file && $0.argument == site.argument
                    }
            }
            .map { "\($0.file): .disabled(\($0.argument))" }
        #expect(offenders.isEmpty,
                "\(offenders.count) control(s) spell their enabling condition out at the surface instead of naming it once on CaptureController: \(offenders.joined(separator: " | "))")
    }

    /// And the exception list cannot rot: an entry whose site is gone, or whose
    /// condition has been edited, fails here — which is how a list of two stays
    /// a list of two rather than becoming the place conditions are parked.
    @Test func everyStatedExceptionIsStillThere() throws {
        let all: [Site] = try sites()
        for exception: Exception in Self.exceptions {
            let present: Bool = all.contains {
                $0.file == exception.file && $0.argument == exception.argument
            }
            #expect(present,
                    "\(exception.file) no longer has .disabled(\(exception.argument)), so its exception (\(exception.reason)) is stale")
        }
    }

    /// The rules the sites now ask for are real properties with real answers,
    /// not names that happen to compile: a fresh controller has no takes, no
    /// markers, no LUTs, nothing running, and every one of these says so.
    ///
    /// This is the half a source walk cannot check. A condition moved onto the
    /// controller INVERTED still satisfies the walk perfectly.
    @Test @MainActor func theNamedRulesAnswerForAnIdleApp() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.hasTakes)
            #expect(!controller.canExportSelects)
            #expect(!controller.hasPlaybackMarkers)
            #expect(!controller.canDropMarker)
            #expect(!controller.hasLUTs)
            #expect(!controller.canGrabFrame)
            #expect(!controller.canMonitorAudio)
            #expect(!controller.canUseVisualRec)
            #expect(!controller.hasVisualRecReferences)
            #expect(!controller.isOffloadRunning)
            #expect(!controller.canStartOffload)
            #expect(!controller.canStopDiskJob)
            #expect(controller.canStartVerify, "no disk job is running")
            #expect(!controller.isDailiesRunning)
            #expect(!controller.canStartDailies)
            #expect(!controller.canSteerDailiesQueue)
            #expect(controller.canChangeRecordingFormat, "nothing is recording")
        }
    }
}
