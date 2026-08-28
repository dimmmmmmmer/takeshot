import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Re-importing a look that is already in the library.
///
/// Three arms, all of them file operations on the operator's own look folder
/// and one of them a DELETE, and none of them had ever executed: they sit
/// behind `NSAlert.runModal()`, which stops the calling thread until somebody
/// clicks. `DuplicateLookPrompt` is the seam that lets the suite answer, the
/// same shape and for the same reason as `FilePanel`.
@Suite @MainActor struct ControllerLookDuplicateTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// A minimal but real .cube. `title` goes in the TITLE line so two files of
    /// the same NAME can still be told apart by their bytes — which is the only
    /// way to say whether "Replace" replaced anything.
    private func writeCube(at url: URL, title: String) throws {
        let body = """
        TITLE "\(title)"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The library pointed at its own scratch folder, with the prompt answering
    /// `answer` instead of opening an alert. The handler is restored on the way
    /// out — the suite is serial, so a substitution cannot leak sideways, but a
    /// leaked one would hang the next test that imports rather than fail it.
    private func withLibrary(
        answering answer: CaptureController.DuplicateLUTChoice,
        _ body: (CaptureController, URL) async throws -> Void) async throws {
        let box = try scratch()
        defer { try? FileManager.default.removeItem(at: box) }
        let asked = Asked()
        let previous = DuplicateLookPrompt.handler
        DuplicateLookPrompt.handler = { name in
            asked.names.append(name)
            return answer
        }
        defer { DuplicateLookPrompt.handler = previous }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = box.appendingPathComponent("LUTs")
            controller.resolveLUTDirectory = box.appendingPathComponent("Resolve")
            try await body(controller, box)
            #expect(asked.names == ["Show_LUT.cube"],
                    "the duplicate prompt was not asked exactly once")
        }
    }

    /// What the substituted prompt was asked. A reference type because the
    /// handler is a plain closure the test reads afterwards.
    private final class Asked {
        var names: [String] = []
    }

    /// Import one look, then offer a DIFFERENT file under the same name.
    private func importThenOfferAgain(_ controller: CaptureController,
                                      in box: URL) throws -> URL {
        let first = box.appendingPathComponent("first/Show_LUT.cube")
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCube(at: first, title: "original")
        controller.adoptLooks(from: [first])
        try #require(controller.availableLUTs.count == 1)

        let second = box.appendingPathComponent("second/Show_LUT.cube")
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCube(at: second, title: "replacement")
        return second
    }

    private func title(ofLookNamed name: String,
                       in controller: CaptureController) throws -> String {
        let url = controller.lutsDirectory.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first)
        return String(line)
    }

    // MARK: - the three arms

    /// Replace: one look in the library afterwards, and it is the NEW bytes.
    /// Asserted on the CONTENT rather than on the count — a replace that
    /// deleted the old file and failed to copy the new one also leaves one
    /// entry, and it would be the wrong one.
    @Test func replacingLeavesOneLookAndItIsTheNewOne() async throws {
        try await withLibrary(answering: .replace) { controller, box in
            let second = try importThenOfferAgain(controller, in: box)

            controller.adoptLooks(from: [second])

            #expect(controller.availableLUTs.map(\.fileName) == ["Show_LUT.cube"])
            #expect(try title(ofLookNamed: "Show_LUT.cube", in: controller)
                    .contains("replacement"),
                    "the look on disk is still the one that was replaced")
            #expect(controller.settings.lut.fileName == "Show_LUT.cube")
            #expect(controller.lastError == nil)
        }
    }

    /// Keep both: two looks, under different names, and the NEW one is the one
    /// now selected — the operator just imported it.
    @Test func keepingBothLeavesTwoLooksAndSelectsTheNewOne() async throws {
        try await withLibrary(answering: .keepBoth) { controller, box in
            let second = try importThenOfferAgain(controller, in: box)

            controller.adoptLooks(from: [second])

            let names = controller.availableLUTs.map(\.fileName).sorted()
            #expect(names.count == 2, "keep-both left \(names)")
            #expect(names.contains("Show_LUT.cube"))
            let added = try #require(names.first { $0 != "Show_LUT.cube" })
            #expect(controller.settings.lut.fileName == added,
                    "the look just imported is not the selected one")
            // the original is untouched under its own name
            #expect(try title(ofLookNamed: "Show_LUT.cube", in: controller)
                    .contains("original"))
            #expect(try title(ofLookNamed: added, in: controller)
                    .contains("replacement"))
        }
    }

    /// Skip: the library and the SELECTION are both left exactly as they were.
    ///
    /// The selection is the half worth asserting. `adoptLooks` selects the last
    /// look it actually copied, so a skipped import must not re-select — and
    /// "must not select" and "must not copy" are two claims: an implementation
    /// that skipped the copy but still named the file would silently repoint
    /// the operator's look at a file it did not write.
    @Test func skippingLeavesTheLibraryAndTheSelectionAlone() async throws {
        try await withLibrary(answering: .skip) { controller, box in
            let second = try importThenOfferAgain(controller, in: box)
            controller.selectLUT(fileName: nil)
            try #require(controller.settings.lut.fileName == nil)

            controller.adoptLooks(from: [second])

            #expect(controller.availableLUTs.map(\.fileName) == ["Show_LUT.cube"])
            #expect(try title(ofLookNamed: "Show_LUT.cube", in: controller)
                    .contains("original"),
                    "a skipped import overwrote the look anyway")
            #expect(controller.settings.lut.fileName == nil,
                    "a skipped import changed which look is applied")
            #expect(controller.lastError == nil)
        }
    }

    /// A name that is NOT already in the library never reaches the prompt at
    /// all. Without this the three above would pass against an implementation
    /// that asked on every single import.
    @Test func aLookWithAFreeNameIsNeverAskedAbout() async throws {
        let box = try scratch()
        defer { try? FileManager.default.removeItem(at: box) }
        let asked = Asked()
        let previous = DuplicateLookPrompt.handler
        DuplicateLookPrompt.handler = { name in
            asked.names.append(name)
            return .skip
        }
        defer { DuplicateLookPrompt.handler = previous }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = box.appendingPathComponent("LUTs")
            controller.resolveLUTDirectory = box.appendingPathComponent("Resolve")
            let source = box.appendingPathComponent("Fresh.cube")
            try writeCube(at: source, title: "fresh")

            controller.adoptLooks(from: [source])

            #expect(asked.names.isEmpty,
                    "a look with a free name was asked about: \(asked.names)")
            #expect(controller.availableLUTs.map(\.fileName) == ["Fresh.cube"])
        }
    }

    // MARK: - the alert itself

    /// The button in position N of the real alert is the one position N
    /// resolves to.
    ///
    /// This is the thing the seam exists to make visible. `NSAlert` answers
    /// with a POSITION, so the buttons and the mapping are two halves of one
    /// list; written apart, inserting or reordering a button leaves both halves
    /// compiling and swaps what two of the three buttons DO — the operator
    /// presses "Skip" and a look is overwritten. Built and never shown:
    /// constructing an `NSAlert` costs nothing, it is `runModal()` that stops
    /// the thread.
    @Test func theButtonsAreInTheOrderTheAnswersResolveIn() {
        let alert = DuplicateLookPrompt.configured(name: "Show_LUT.cube")
        let responses: [NSApplication.ModalResponse] = [
            .alertFirstButtonReturn, .alertSecondButtonReturn,
            .alertThirdButtonReturn
        ]
        #expect(alert.buttons.count == DuplicateLookPrompt.order.count)
        for (index, option) in DuplicateLookPrompt.order.enumerated() {
            #expect(alert.buttons[index].title == L(option.titleKey),
                    "button \(index) is \(alert.buttons[index].title)")
            #expect(DuplicateLookPrompt.choice(for: responses[index])
                    == option.choice,
                    "response \(index) does not resolve to \(option.choice)")
        }
        // the destructive answer is the one under the return key, and the
        // three buttons are three different words
        #expect(DuplicateLookPrompt.order.first?.choice == .replace)
        #expect(Set(alert.buttons.map(\.title)).count == 3,
                "two buttons carry the same title: \(alert.buttons.map(\.title))")
        // …and the alert names the file, so an operator with several imports in
        // flight can tell which one is being asked about
        #expect(alert.messageText.contains("Show_LUT.cube"))
        #expect(!alert.informativeText.isEmpty)
    }

    /// Anything outside the three buttons is SKIP, and that is the safe answer
    /// rather than an arbitrary one: an alert dismissed by a route nobody
    /// anticipated must not read as permission to delete the look already in
    /// the library.
    @Test func anUnrecognizedResponseIsTheSafeAnswer() {
        for response: NSApplication.ModalResponse in [
            .cancel, .abort, .stop, .continue, .alertThirdButtonReturn
        ] where response != .alertFirstButtonReturn {
            let choice = DuplicateLookPrompt.choice(for: response)
            #expect(choice != .replace,
                    "\(response.rawValue) was read as permission to overwrite")
        }
        #expect(DuplicateLookPrompt.choice(for: .cancel) == .skip)
        #expect(DuplicateLookPrompt
            .choice(for: NSApplication.ModalResponse(rawValue: 1_003)) == .skip,
                "a fourth button's response was not read as skip")
    }

    /// Both languages have all five strings the alert is built from. A missing
    /// key renders as the key itself, which no build step notices and which
    /// puts `lut_keep_both` on a button.
    @Test func theAlertIsTranslated() {
        let keys = ["lut_duplicate_title", "lut_duplicate_text"]
            + DuplicateLookPrompt.order.map(\.titleKey)
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in keys {
                    #expect(L(key) != key, "\(language) is missing \(key)")
                }
                let titles = DuplicateLookPrompt.order.map { L($0.titleKey) }
                #expect(Set(titles).count == 3,
                        "\(language) button titles collide: \(titles)")
            }
        }
    }
}
