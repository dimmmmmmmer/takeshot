import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The sync-play grid through the render harness: the display rule at mount
/// level, and the chrome measured in both languages.
@MainActor
struct ViewSyncPlayTests {
    /// A controller in sync-play on `count` seeded takes; returns the model.
    private func startSession(_ probe: ViewProbe,
                              count: Int) throws -> SyncPlayModel {
        let takes = (1...count).map { index in
            ControllerFixtures.take(
                named: "TS_A001C0\(index)", in: probe.root, clip: index,
                recordedAt: Date(timeIntervalSinceNow: Double(index) * 10))
        }
        for take in takes {
            try ControllerFixtures.placeholder(for: take)
        }
        probe.controller.takes = takes
        probe.controller.selectedItems = Set(takes.map(\.url))
        MediaFixtures.silence(probe.controller)
        probe.controller.startSyncPlay()
        return try #require(probe.controller.syncPlay)
    }

    /// The preview display rule, on the real player area: every tile mounts
    /// its OWN layer with its OWN tap, and the single re-routed ViewerSurface
    /// is not in the tree at all — the main tap gains no sink.
    @Test func everyTileMountsItsOwnLayerAndTheMainSurfaceStaysOut() async throws {
        try await ViewProbe.run { probe in
            let model = try startSession(probe, count: 4)
            defer { probe.controller.endSyncPlay() }

            await probe.mounted(PreviewView()) {
                var layers: Set<ObjectIdentifier> = []
                for tile in model.tiles {
                    let sinks = tile.tap.sinks.all()
                    #expect(sinks.count == 1,
                            "a tile mounted \(sinks.count) layers, not its own one")
                    layers.formUnion(sinks.map(ObjectIdentifier.init))
                }
                #expect(layers.count == 4, "two tiles are sharing a layer")
                #expect(probe.controller.playbackTap.sinks.all().isEmpty,
                        "the single viewer surface was multiplied into the grid")
            }
        }
    }

    /// Ending the session releases the mounts: nothing keeps feeding layers
    /// nobody is looking at.
    @Test func closingTheSessionUnmountsTheTiles() async throws {
        try await ViewProbe.run { probe in
            let model = try startSession(probe, count: 2)

            await probe.mounted(PreviewView()) {
                #expect(model.tiles.allSatisfy { $0.tap.sinks.all().count == 1 })
                probe.controller.endSyncPlay()
            }
            // the mounts detach with the view; the registries hold weakly, so
            // the assertion is that the session is gone and its taps stopped
            #expect(probe.controller.syncPlay == nil)
        }
    }

    /// The header plate — alignment picker, TC-fallback note, close button —
    /// in its widest configuration (the fallback note showing), in both
    /// languages, inside the chrome row the player gives it.
    @Test func theHeaderFitsThePlayerChromeInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            // disjoint TCs in by-timecode mode: the fallback note is up
            let sources = [
                SyncPlayModel.Source(
                    url: probe.root.appendingPathComponent("a.mov"), name: "A",
                    startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                            frames: 0, fps: 25),
                    duration: 4),
                SyncPlayModel.Source(
                    url: probe.root.appendingPathComponent("b.mov"), name: "B",
                    startTimecode: Timecode(hours: 11, minutes: 0, seconds: 0,
                                            frames: 0, fps: 25),
                    duration: 4),
            ]
            let model = SyncPlayModel(sources: sources,
                                      alignmentMode: .byTimecode)
            defer { model.shutDown() }
            #expect(!model.schedule.usedTimecode, "the note must be on screen")

            let ideal = probe.fittingSizes { SyncPlayHeader(model: model) }
            #expect(ideal.en.width <= ViewBudget.playerChromeWidth,
                    "EN header wants \(ideal.en.width)pt")
            #expect(ideal.ru.width <= ViewBudget.playerChromeWidth,
                    "RU header wants \(ideal.ru.width)pt")
            #expect(ideal.ru.height <= PlayerChrome.height,
                    "the header grew past its plate: \(ideal.ru.height)pt")
        }
    }

    /// The master transport bar is icons and monospaced digits — like the
    /// other two bars, it must measure identically in both languages and fit
    /// the strip the player reserves for a transport.
    @Test func theTransportFitsItsStripInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = try startSession(probe, count: 2)
            defer { probe.controller.endSyncPlay() }

            let ideal = probe.fittingSizes { SyncPlayTransportBar(model: model) }
            #expect(ideal.ru == ideal.en,
                    "a localized label reached the sync transport: \(ideal)")
            #expect(ideal.ru.width <= ViewBudget.transportWidth,
                    "the sync transport wants \(ideal.ru.width)pt")
            #expect(ideal.ru.height <= ViewBudget.transportHeight)
        }
    }

    /// The master transport carries a LEVEL, not just a routing choice.
    ///
    /// The tiles' speaker buttons pick which take is audible; that was the whole
    /// of the grid's audio, so a comparison could be moved between takes and
    /// never turned down or off. The control is `TransportVolume` — the same
    /// speaker-plus-slider the single player's transport has, on the same one
    /// shared level — so the bar now holds two sliders: the scrubber and the
    /// level.
    ///
    /// Counted as real AppKit sliders (the `theFieldInstallsItsFormatter` idiom),
    /// and gated on the count being able to see one at all: a structural count
    /// that silently returns zero on some host would otherwise "prove" the
    /// control is missing — or, worse, pass for having found nothing.
    @Test func theMasterTransportCarriesTheMonitoringLevel() async throws {
        try await ViewProbe.run { probe in
            let model = try startSession(probe, count: 2)
            defer { probe.controller.endSyncPlay() }

            let reference: Int = Self.sliderCount(
                probe.hosted(Slider(value: .constant(0.5), in: 0...1)))
            try #require(reference == 1,
                         "this host does not render a Slider as an NSSlider, so the count below would prove nothing")

            let bar: Int = Self.sliderCount(
                probe.hosted(SyncPlayTransportBar(model: model)))
            #expect(bar == 2,
                    "the sync transport has \(bar) slider(s): the scrubber, and no monitoring level")
            // …and it is the app's ONE level, so it reads what the app is at.
            probe.controller.monitorVolume = 0.25
            #expect(probe.controller.playbackVolume == 0.25)
            #expect(model.volume == 0.25,
                    "the bar's level and the grid's are not the same level")
            probe.controller.monitorVolume = 0
        }
    }

    /// How many real sliders a view puts on screen.
    private static func sliderCount(_ view: some View) -> Int {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: ViewBudget.transportWidth,
                            height: 60)
        host.layoutSubtreeIfNeeded()
        return countSliders(in: host)
    }

    private static func countSliders(in view: NSView) -> Int {
        if view is NSSlider { return 1 }
        return view.subviews.reduce(0) { $0 + countSliders(in: $1) }
    }

    /// The whole grid view renders at the player's size in both languages —
    /// tiles, labels and chrome — without stretching its host.
    @Test func theGridLaysOutAtThePlayersSizeInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let model = try startSession(probe, count: 3)
            defer { probe.controller.endSyncPlay() }

            let size = CGSize(width: ViewBudget.playerWidth, height: 500)
            for language in [AppLanguage.english, .russian] {
                let laid = ViewRender.withLanguage(language) {
                    ViewRender.laidOutSize(
                        probe.hosted(SyncPlayView(model: model)), in: size)
                }
                #expect(laid == size,
                        "\(language.rawValue): the grid stretched to \(laid)")
            }
        }
    }
}
