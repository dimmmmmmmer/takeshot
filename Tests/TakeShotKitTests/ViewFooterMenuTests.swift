import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **Two menus in one bar wear one disclosure.**
///
/// The codec menu hid the system indicator and drew a 7pt chevron by hand;
/// the naming menu beside it showed the real one. Measured, that was 24pt
/// against 38 — and at 7pt the mark reads as nothing, so the codec looked
/// like a readout and its neighbour like a menu (owner: "у кнопки кодека нет
/// рядом с иконкой стрелочки вниз как у иконки наименований").
///
/// Measured rather than grepped: what went wrong was how BIG the mark was,
/// and a source rule saying "draws a chevron" was satisfied the whole time.
@Suite @MainActor struct ViewFooterMenuTests {
    @Test func theCodecMenuLooksAsMuchLikeAMenuAsTheOneBesideIt() async throws {
        try await ViewProbe.run { probe in
            let codec = probe.fittingSizes { probe.hosted(FooterCodecMenu()) }
            let naming = probe.fittingSizes { probe.hosted(NamingPresetMenu()) }
            #expect(abs(codec.en.width - naming.en.width) <= 4,
                    "codec \(codec.en.width)pt vs naming \(naming.en.width)pt")
            #expect(abs(codec.ru.width - naming.ru.width) <= 4,
                    "codec \(codec.ru.width)pt vs naming \(naming.ru.width)pt")
            // …and both are wide enough to be carrying an indicator at all: an
            // icon alone measures about 19.
            #expect(codec.en.width > 30,
                    "the codec menu is \(codec.en.width)pt — icon only?")
        }
    }
}
