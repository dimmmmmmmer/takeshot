import Foundation
import Testing

@testable import TakeShotKit

/// **The address row is not a `Button`, and that is the fix.**
///
/// A double click was asked for and implemented as
/// `.simultaneousGesture(TapGesture(count: 2))` on a `Button` — which does not
/// fire: the button's own gesture recognizes the first click and ends the
/// sequence, so the pair never completes and the address never opened (owner:
/// "клики по ссылкам ремоут контрола все еще не открывают браузер", after the
/// first attempt had already shipped).
///
/// Two `onTapGesture`s on a plain row is the arrangement that works — SwiftUI
/// tries the higher count first and falls back to the single click, so one
/// click still copies and points the QR at that line.
///
/// Asserted on the source: which gesture a rendered row would recognize is not
/// observable from a headless layout, and the failure is silent — the control
/// looks right and does nothing.
@Suite struct ViewRemoteAddressClickTests {
    private func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit/RemoteSettingsSection.swift"),
                   encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theAddressRowUsesTapGesturesAndNotAButtonsSimultaneousOne() throws {
        let code = try source()
        #expect(code.contains("onTapGesture(count: 2)"),
                "the double click is not a tap gesture")
        #expect(!code.contains("simultaneousGesture(TapGesture"), """
            the double click is a simultaneous gesture again — on a Button that \
            never completes
            """)
    }

    /// Both halves survive: a double click opens, a single click copies. It
    /// would be easy to "fix" the open by taking the copy away, and the copy
    /// is what the address is FOR — the Mac is not the device that needs it.
    @Test func oneClickStillCopiesAndPointsTheCodeAtThatLine() throws {
        let code = try source()
        #expect(code.contains("RemoteHandout.open(url)"))
        #expect(code.contains("RemoteHandout.copy(url)"))
        #expect(code.contains("chosen = index"),
                "a single click no longer points the QR at the line clicked")
    }

    /// A plain row is not a control until it says so. The `Button` carried the
    /// trait for free; taking it away must not take VoiceOver with it.
    @Test func theRowStillAnnouncesItselfAsAControl() throws {
        let code = try source()
        #expect(code.contains("accessibilityAddTraits(.isButton)"),
                "the address row is invisible to VoiceOver as a control")
    }
}
