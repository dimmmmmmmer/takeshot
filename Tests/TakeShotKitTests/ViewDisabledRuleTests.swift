import Foundation
import Testing

@testable import TakeShotKit

/// Where a control's enabling condition is allowed to live.
///
/// **The finding this exists for.** A condition copied per surface is this
/// codebase's most productive source of bugs, measured on its own history:
/// add-marker had five surfaces, three rules between them, and two of those
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
/// surface will write slightly differently.
///
/// The negation is allowed because `!` reverses a rule without restating it; a
/// second term does not. The receiver has to be `controller` because that is
/// where app state lives: a run's own model (`offload`, `dailies`, `verify`) is
/// reached THROUGH the controller, in the domain extension that owns it, so the
/// sheet, the menu item and the takes-panel strip cannot end up with three
/// spellings of "is it going" — which is exactly what they had.
///
/// **The exception carries its reason at the site, and this test holds no list.**
/// A list here would be a second copy of a fact about the source — the same
/// mistake one rung up, and it goes stale the way a hard-coded count does. A site
/// that genuinely cannot comply writes `disabled(exception):` in the comment
/// immediately above it, with the reason, and the marker travels with the code
/// when it moves. There is nothing to maintain and nothing to renumber; what
/// there is instead is a grep that shows every exception in the tree at once.
struct ViewDisabledRuleTests {
    /// One `.disabled(` in the tree: what it says, and what the comment above it
    /// says about why.
    struct Site {
        let file: String
        let line: Int
        let argument: String
        /// The `disabled(exception):` reason from the comment block above, or nil
        /// when there is none.
        let exemption: String?
    }

    /// A marker with nothing after it is not a reason. Long enough to have to be
    /// a sentence, short enough that a real one clears it without padding.
    static let reasonFloor: Int = 40

    /// `controller.name` or `!controller.name`, and nothing else.
    private func namesOneRule(_ argument: String) -> Bool {
        let body: String = argument.hasPrefix("!")
            ? String(argument.dropFirst()) : argument
        guard body.hasPrefix("controller.") else { return false }
        let name: String = String(body.dropFirst("controller.".count))
        guard let first: Character = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The line with any trailing `//` comment cut off, so a comment ABOUT this
    /// rule is never read as a violation of it.
    private func code(of line: String) -> String {
        guard let comment: Range<String.Index> = line.range(of: "//") else {
            return line
        }
        return String(line[line.startIndex..<comment.lowerBound])
    }

    /// The argument of the `.disabled(` on `lines[index]`, by paren balance, so a
    /// condition spread over several lines is read whole rather than truncated
    /// into something that happens to look compliant.
    private func argument(in lines: [String], from index: Int) -> String? {
        var depth: Int = 0
        var collected: String = ""
        var started: Bool = false
        for cursor: Int in index..<lines.count {
            var text: String = code(of: lines[cursor])
            if !started, let hit: Range<String.Index> = text.range(of: ".disabled(") {
                text = String(text[hit.lowerBound...].dropFirst(".disabled".count))
                started = true
            }
            for character: Character in text {
                if character == "(" {
                    depth += 1
                    if depth == 1 { continue }
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        return collected
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                collected.append(character)
            }
            collected.append(" ")
        }
        return nil
    }

    /// The `disabled(exception):` reason in the comment block directly above
    /// `index`, or nil. Contiguous `//` lines only: a reason two blank lines up
    /// is a reason about something else.
    private func exemption(in lines: [String], above index: Int) -> String? {
        var block: [String] = []
        var cursor: Int = index - 1
        while cursor >= 0 {
            let trimmed: String = lines[cursor]
                .trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { break }
            block.insert(String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespaces), at: 0)
            cursor -= 1
        }
        let marker: String = "disabled(exception):"
        guard let start: Int = block.firstIndex(where: { $0.hasPrefix(marker) })
        else { return nil }
        var reason: String = String(block[start].dropFirst(marker.count))
        for extra: String in block[(start + 1)...] {
            reason += " " + extra
        }
        return reason.trimmingCharacters(in: .whitespaces)
    }

    /// Every `.disabled(` under `Sources/TakeShotKit`.
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
            let lines: [String] = raw.components(separatedBy: "\n")
            for index: Int in lines.indices
            where code(of: lines[index]).contains(".disabled(") {
                guard let value: String = argument(in: lines, from: index)
                else { continue }
                found.append(Site(file: url.lastPathComponent,
                                  line: index + 1,
                                  argument: value,
                                  exemption: exemption(in: lines, above: index)))
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        // Not a pinned count — a floor under "the walk found the controls at
        // all", so a broken extractor cannot come back green having read nothing.
        try #require(found.count > 40,
                     "the walk found almost no .disabled( sites, so a green run here would mean nothing")
        return found
    }

    /// The rule itself.
    @Test func everyDisabledSiteNamesItsRuleOnTheController() throws {
        let offenders: [String] = try sites()
            .filter { !namesOneRule($0.argument) && $0.exemption == nil }
            .map { "\($0.file):\($0.line) .disabled(\($0.argument))" }
        let named: String = offenders.joined(separator: " | ")
        #expect(
            offenders.isEmpty,
            "\(offenders.count) control(s) spell the rule out at the surface: \(named)")
    }

    /// And an exception has to SAY something. The marker is the escape hatch, so
    /// the reason is what it costs; a bare marker would make the rule optional.
    @Test func everyExceptionGivesARealReason() throws {
        let thin: [String] = try sites()
            .filter { site in
                guard let reason: String = site.exemption else { return false }
                return reason.count < Self.reasonFloor
            }
            .map { "\($0.file):\($0.line) \"\($0.exemption ?? "")\"" }
        #expect(
            thin.isEmpty,
            "\(thin.count) exception marker(s) carry no reason worth reading: \(thin.joined(separator: " | "))")
    }

    /// An exception on a site that COULD comply is not an exception. This is what
    /// stops the marker being pasted around: the moment a site's condition is
    /// moved onto the controller, its marker has to go with it.
    @Test func noCompliantSiteCarriesAnException() throws {
        let pointless: [String] = try sites()
            .filter { namesOneRule($0.argument) && $0.exemption != nil }
            .map { "\($0.file):\($0.line) .disabled(\($0.argument))" }
        #expect(
            pointless.isEmpty,
            "\(pointless.count) site(s) claim an exception they do not need: \(pointless.joined(separator: " | "))")
    }

    /// The rules the sites now ask for are real properties with real answers, not
    /// names that happen to compile: a fresh controller has no takes, no markers,
    /// no LUTs and nothing running, and every one of these says so.
    ///
    /// This is the half a source walk cannot check — a condition moved onto the
    /// controller INVERTED satisfies the walk perfectly.
    @Test @MainActor func theNamedRulesAnswerForAnIdleApp() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.hasTakes)
            #expect(!controller.canExportSelects)
            #expect(!controller.hasPlaybackMarkers)
            #expect(!controller.canDropMarker)
            // The look library is the OPERATOR's own folder unless a test
            // redirects it (`ControllerHarness` does not), so asking a fresh
            // controller whether it has looks asks the machine running the
            // suite. Both directions are asked against a list this test owns
            // instead, which is the stronger question anyway: an inverted move
            // is what a source walk cannot see.
            controller.availableLUTs = []
            #expect(!controller.hasLUTs)
            controller.availableLUTs = [CaptureController.LUTInfo(
                fileName: "show.cube", name: "show")]
            #expect(controller.hasLUTs, "a library with a look in it reads as empty")
            controller.availableLUTs = []
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
