import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The PIN gate on all four pages.**
///
/// Two complaints, one gate: the pages opened showing "Wrong PIN" before
/// anybody had touched anything ("ремоут страницы дефолтно открываются с
/// надписью неправильный пин"), and the code needed a Connect button to be
/// tried at all ("давай сразу при вводе пина без кнопки коннект пускать/не
/// пускать").
///
/// Asserted against the SERVED page rather than the file on disk: what the
/// phone gets is the template with the config spliced in, and the config is
/// half of what this is about.
@Suite @MainActor struct RemoteGateTests {
    private func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    private var pages: [(name: String, html: String)] {
        [("remote", text(RemotePage.html())),
         ("slate", text(RemotePage.slateHTML())),
         ("live", text(RemotePage.liveHTML())),
         ("script", text(RemotePage.scriptHTML()))]
    }

    @Test func noPageStillHasAConnectButton() {
        for page in pages {
            #expect(!page.html.contains("id=\"connect\""),
                    Comment(rawValue: "\(page.name) still has the button"))
        }
    }

    /// The gate tries the code as it is typed.
    @Test func everyPageSubmitsAsTheLastDigitLands() {
        for page in pages {
            #expect(page.html.contains("addEventListener(\"input\", submitPIN)"),
                    Comment(rawValue: "\(page.name) does not try the code as it is typed"))
            #expect(page.html.contains("value.length < CFG.pinLength"),
                    Comment(rawValue: "\(page.name) does not know how long the code is"))
        }
    }

    /// **No page accuses the operator directly.** Every refusal goes through
    /// `refusePIN`, which is where the difference between "you typed this" and
    /// "I remembered this" lives — and that difference is the whole bug.
    @Test func everyRefusalGoesThroughTheOneThatKnowsWhoTyped() {
        for page in pages {
            #expect(!page.html.contains("showGate(S.pinBad)"),
                    Comment(rawValue: "\(page.name) accuses without asking who typed"))
            #expect(page.html.contains("function refusePIN()"),
                    Comment(rawValue: "\(page.name) has no refusePIN"))
            #expect(page.html.contains("showGate(accused ? S.pinBad : \"\")"),
                    Comment(rawValue: "\(page.name) refuses without the distinction"))
        }
    }

    /// The length reaches the page from the app rather than being typed into
    /// four HTML files — the pages submit on it, so a PIN that changed length
    /// would leave every gate unable to finish.
    @Test func theConfigCarriesThePinLengthTheAppGenerates() {
        for page in pages {
            #expect(page.html.contains("pinLength:\(RemoteSettings.pinLength)"),
                    Comment(rawValue: "\(page.name) was served no pin length"))
        }
        #expect(RemotePIN.generate().count == RemoteSettings.pinLength)
    }

    /// A generated code is the length the pages are told to expect, every
    /// time — including the ones with leading zeros, which is what the
    /// zero-padded format is for and what a naive `String(Int)` loses.
    @Test func everyGeneratedCodeIsFullLength() {
        for _ in 1...200 {
            let pin = RemotePIN.generate()
            #expect(pin.count == RemoteSettings.pinLength,
                    Comment(rawValue: "generated \(pin)"))
            #expect(pin.allSatisfy { $0.isNumber })
        }
    }
}
