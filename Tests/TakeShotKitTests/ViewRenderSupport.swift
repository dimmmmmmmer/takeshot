import AVFoundation
import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

// Headless rendering fixtures for the SwiftUI layer.
//
// The views had no coverage at all, because every one of them needs a live
// CaptureController and nothing in a test can show a window. `NSHostingView`
// does not need one: give it a root view, ask for a size, and the real `body`,
// the real modifiers and the real AppKit text measurement all run.
//
// That is what these fixtures are for. Russian runs 1.5-3x longer than English
// and the failure mode is silent — a label truncates inside a fixed-width
// control, a row grows a second line, a centered group slides under the badge
// beside it. None of that throws; all of it shows up as a size. Every View*
// suite renders in both languages and compares the result against the budget
// the app actually gives that view.
//
// Three ways to ask, and they answer different questions:
//   fittingSize  — what the view WANTS (its ideal size). Compare against the
//                  space the app has for it.
//   size(proposedWidth:) — what it settles for. Proposing 1pt returns the
//                  narrowest it can be squeezed to, which is the number that
//                  says whether a popover of fixed width clips its own rows.
//   laidOutSize  — the frame an exact-size host ends up with; for "this overlay
//                  must not stretch the player".

/// Height proposed when only the width is under test. Not `.infinity`: SwiftUI
/// hands that straight through to `maxHeight: .infinity` children and the
/// measurement comes back infinite. Outside the main-actor namespaces below so
/// it can be a default argument there.
private let looseHeight: CGFloat = 4000

@MainActor
enum ViewRender {
    /// The size a view asks for with nothing constraining it.
    ///
    /// Only meaningful for self-sizing chrome — bars, badges, popover bodies,
    /// rows. A view that stretches reports the proposal it was handed instead.
    static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        // sizingOptions is what makes the host adopt the SwiftUI content size
        // rather than keeping the frame it was created with.
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The size a view settles on when its container proposes `width`.
    ///
    /// Content that cannot compress answers with MORE than the proposal — which
    /// is exactly the signal for "this does not fit".
    static func size(_ view: some View, proposedWidth width: CGFloat,
                     proposedHeight height: CGFloat = looseHeight) -> CGSize {
        let controller = NSHostingController(rootView: AnyView(view))
        // Force the view tree to exist first: sizeThatFits on a controller
        // whose view was never loaded hands the proposal back unchanged.
        _ = controller.view
        return controller.sizeThatFits(in: CGSize(width: width, height: height))
    }

    /// The narrowest the view can be squeezed to.
    static func minimumWidth(_ view: some View,
                             proposedHeight height: CGFloat = looseHeight) -> CGFloat {
        size(view, proposedWidth: 1, proposedHeight: height).width
    }

    /// Lay a view out at an exact size and report the frame the host ended up
    /// with. Used for "an overlay must not stretch its host": the answer has to
    /// stay the size that was asked for.
    static func laidOutSize(_ view: some View, in size: CGSize) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host.frame.size
    }

    /// Mount a view at an exact size and keep the host alive for `body`.
    ///
    /// The measuring calls above ask a question about geometry and let the host
    /// go the moment they answer it. The preview surfaces need the opposite: an
    /// `NSViewRepresentable` registers its Metal layer with a frame producer in
    /// `makeNSView`, and every sink registry holds its layers WEAKLY — so a host
    /// released before the assertion runs takes the very mounts under test with
    /// it, and "this window mounted no compare pane" and "this window's pane was
    /// already collected" become the same green.
    /// `body` is async because what a mounted surface is FED only arrives after
    /// a decoder has run; the host outlives the wait.
    static func mounted<T>(_ view: some View,
                           in size: CGSize = CGSize(width: 1280, height: 720),
                           _ body: () async throws -> T) async rethrows -> T {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(host) {} }
        return try await body()
    }

    /// Rasterize a view offscreen and report, in points, which columns it drew
    /// something bright in.
    ///
    /// Everything else here answers "how big is it". This answers "is it there,
    /// and where" — the question a shared overlay raises, because nothing about
    /// a window's size says whether that window mounted the overlay. The wipe
    /// seam is a white line and a white dot over a dark picture, so a column
    /// histogram is enough to say both that it is drawn and where the seam
    /// landed.
    ///
    /// `rows` narrows the scan to a horizontal band, given as a fraction of the
    /// height. A player surface has chrome — a transport strip along the
    /// bottom, badges along the top — and every one of those is bright too, so
    /// a scan of the whole frame answers "something is lit somewhere", which is
    /// not a question worth asking.
    static func brightColumns(_ view: some View, in size: CGSize,
                              rows: ClosedRange<Double> = 0...1,
                              threshold: Int = 200) -> [Int] {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return [] }
        host.cacheDisplay(in: host.bounds, to: rep)
        // The backing store is 2x on a Retina machine and 1x on a headless CI
        // runner; the assertions are in points either way.
        let scale = max(1, rep.pixelsWide / max(1, Int(size.width)))
        let band = Int(Double(rep.pixelsHigh) * rows.lowerBound)
            ..< max(1, Int(Double(rep.pixelsHigh) * rows.upperBound))
        var columns: Set<Int> = []
        for x in 0..<rep.pixelsWide {
            for y in band {
                // A bitmap cached from a hosting view comes back in the
                // device's calibrated space, where -getRed:… raises rather than
                // converting. Asking for the value in a known space is the only
                // safe way to read a pixel out of one.
                guard let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.genericRGB) else { continue }
                if Int(color.redComponent * 255) >= threshold {
                    columns.insert(x / scale)
                    break
                }
            }
        }
        return columns.sorted()
    }

    /// Measure the same view in both languages.
    ///
    /// The view is built inside the closure, once per language: `L()` is read
    /// while `body` runs, so the bundle has to be swapped before the tree
    /// exists, not after.
    static func bothLanguages<V: View>(
        _ measure: (V) -> CGSize,
        _ make: () -> V) -> (en: CGSize, ru: CGSize) {
        (en: withLanguage(.english) { measure(make()) },
         ru: withLanguage(.russian) { measure(make()) })
    }

    /// Run `body` with the UI language forced, then put back whatever was in
    /// force before. The bundle L10n holds is process-wide state: a suite that
    /// walks away leaving it on Russian changes what every later suite asserts.
    static func withLanguage<T>(_ language: AppLanguage, _ body: () -> T) -> T {
        let previous = L10n.current
        L10n.apply(language)
        defer { L10n.apply(previous) }
        return body()
    }
}

/// Everything a view needs to render: a controller on a scratch record folder, a
/// hotkey manager, and an `@AppStorage` store that is not the operator's.
///
/// `@AppStorage` is why this exists rather than a bare `ControllerHarness.run`:
/// the takes panel, the other-content section and the scopes panel all read
/// `UserDefaults.standard` through it, and `defaultAppStorage` is the only way
/// to point them somewhere a test may write.
///
/// All three share the controller's scratch suite rather than opening a second
/// one. cfprefsd invalidates a live `UserDefaults` instance's cache when any
/// domain is removed, and a suite per fixture meant `removePersistentDomain`
/// running dozens of extra times — enough, under coverage instrumentation, to
/// drop a value out from under an unrelated suite's read-back.
@MainActor
struct ViewProbe {
    let controller: CaptureController
    let hotkeys: HotkeyManager
    let root: URL
    /// The scratch domain behind `@AppStorage` in the views under test — the
    /// controller's own, emptied around every run by `ControllerHarness`.
    let store: UserDefaults

    static func run(configure: (inout CaptureSettings) -> Void = { _ in },
                    _ body: (ViewProbe) async throws -> Void) async throws {
        try await ControllerHarness.run(configure: configure) { controller, root in
            let store = controller.defaults
            try await body(ViewProbe(controller: controller,
                                     hotkeys: HotkeyManager(defaults: store),
                                     root: root, store: store))
        }
    }

    /// The view with the environment the app gives it. Everything measured here
    /// goes through this, so a missing environment object can never be the
    /// reason a size looks wrong.
    func hosted(_ view: some View) -> some View {
        view
            .environmentObject(controller)
            .environmentObject(hotkeys)
            .defaultAppStorage(store)
    }

    func fittingSize(_ view: some View) -> CGSize {
        ViewRender.fittingSize(hosted(view))
    }

    func size(_ view: some View, proposedWidth width: CGFloat,
              proposedHeight height: CGFloat = looseHeight) -> CGSize {
        ViewRender.size(hosted(view), proposedWidth: width, proposedHeight: height)
    }

    /// Which columns the view actually drew something bright in, in points.
    func brightColumns(_ view: some View, in size: CGSize,
                       rows: ClosedRange<Double> = 0...1) -> [Int] {
        ViewRender.brightColumns(hosted(view), in: size, rows: rows)
    }

    /// Mount a view with the app's environment and hold it there for `body`
    /// (see `ViewRender.mounted` for why the host has to stay alive).
    func mounted<T>(_ view: some View,
                    in size: CGSize = CGSize(width: 1280, height: 720),
                    _ body: () async throws -> T) async rethrows -> T {
        try await ViewRender.mounted(hosted(view), in: size, body)
    }

    /// Ideal size in English and in Russian.
    func fittingSizes<V: View>(_ make: () -> V) -> (en: CGSize, ru: CGSize) {
        ViewRender.bothLanguages({ self.fittingSize($0) }, make)
    }

    /// Size under a proposed width, in English and in Russian.
    func sizes<V: View>(proposedWidth width: CGFloat,
                        proposedHeight height: CGFloat = looseHeight,
                        _ make: () -> V) -> (en: CGSize, ru: CGSize) {
        ViewRender.bothLanguages({
            self.size($0, proposedWidth: width, proposedHeight: height)
        }, make)
    }

    /// Narrowest width in English and in Russian — the number that says whether
    /// a fixed-width container clips what is inside it.
    func minimumWidths<V: View>(proposedHeight height: CGFloat = looseHeight,
                                _ make: () -> V) -> (en: CGFloat, ru: CGFloat) {
        let sizes = ViewRender.bothLanguages({
            self.size($0, proposedWidth: 1, proposedHeight: height)
        }, make)
        return (sizes.en.width, sizes.ru.width)
    }
}

extension CGSize {
    /// Same size to within `slack`.
    ///
    /// For the small self-sizing chrome the suites compare exact sizes, and they
    /// are exact. A grouped Form is different: its height is a sum over three
    /// dozen rows, and the sub-point rounding of that sum is not stable between
    /// runs. `slack` is set well below a line of text, so a row that wrapped or
    /// a section that went missing still fails.
    func matches(_ other: CGSize, slack: CGFloat) -> Bool {
        abs(width - other.width) <= slack && abs(height - other.height) <= slack
    }
}

/// The width and height budgets the app actually gives its views, derived from
/// the frames in the production views rather than invented here. A test that
/// hard-codes 726 says nothing; a test that says "the footer has to fit the
/// narrowest main column" fails for a reason someone can act on.
enum ViewBudget {
    /// `TakeShotApp`: the main window cannot be made narrower than this.
    static let windowMinWidth: CGFloat = 1080
    /// `ContentView.sidePanel`: the takes panel at its narrowest, plus its own
    /// 10pt padding on each side.
    static let panelMinWidth: CGFloat = 310
    static let panelOuterWidth: CGFloat = panelMinWidth + 20
    /// What is left for the player column in the narrowest window.
    static let mainColumnWidth: CGFloat = windowMinWidth - panelOuterWidth
    /// `ContentView` pads the footer by 12 on each side.
    static let footerWidth: CGFloat = mainColumnWidth - 24
    /// The footer's outer HStack splits into two equally flexible halves: the
    /// utilities on the left, the naming fields on the right.
    static let footerHalfWidth: CGFloat = footerWidth / 2
    /// What the footer's left-hand shooting controls actually get: the half,
    /// minus the bar's own 14pt padding a side and the 8pt between the halves,
    /// minus the gap `BottomBarView` reserves for the centered record group.
    static var footerSideZoneWidth: CGFloat {
        (footerWidth - 28 - 8) / 2 - BottomBarView.centerReserve
    }
    /// `PlayerArea` pads the player by 12 on each side.
    static let playerWidth: CGFloat = mainColumnWidth - 24
    /// `PlayerBadges.topChrome` insets the badge row by 8 on each side.
    static let playerChromeWidth: CGFloat = playerWidth - 16
    /// The right-hand badge group — scopes, multicam, assist, LUT and the
    /// format badge. Measured (they are fixed-size icons plus a monospaced
    /// format string), and it is the wider of the two side zones, so it is what
    /// limits the group centered between them.
    static let topBadgeGroupWidth: CGFloat = 185
    /// What the centered mode/compare group can use without reaching into
    /// either side zone.
    static var playerCenterWidth: CGFloat {
        playerChromeWidth - 2 * topBadgeGroupWidth
    }
    /// `PreviewView` insets the transport by 6 on each side.
    static let transportWidth: CGFloat = playerWidth - 12
    /// `PlayerArea` lifts a toast by this much to clear the transport bar — a
    /// taller transport covers the toast.
    static let transportHeight: CGFloat = 52
    /// `PlayerBadges.scopesOverlay` clamps the in-player scopes to this.
    static let scopesOverlayWidth: CGFloat = 860
    /// `SettingsView` renders at a fixed width and pads itself by 16 a side.
    static var settingsFormWidth: CGFloat { SettingsView.width - 32 }
    /// `VancMonitorView`'s own declared minimum.
    static let vancMinWidth: CGFloat = 560
}

/// Fixtures for the views that need content before they render anything worth
/// measuring.
@MainActor
enum ViewFixtures {
    /// A player with nothing loaded: the transport bar reads `duration` and
    /// `rate` off it and an empty one answers both.
    static func idlePlayer() -> AVPlayer { AVPlayer() }

    /// Two takes with ratings and a comment — enough for the list rows, the
    /// grid cells and the export menu's enablement.
    @discardableResult
    static func seedTakes(_ controller: CaptureController,
                          in root: URL) throws -> [Take] {
        var good = ControllerFixtures.take(named: "TS_A001C01", in: root, clip: 1)
        good.rating = .good
        good.comment = "проверка объектива / lens check"
        let plain = ControllerFixtures.take(named: "TS_A001C02", in: root, clip: 2)
        for take in [good, plain] {
            try ControllerFixtures.placeholder(for: take)
        }
        controller.takes = [good, plain]
        return [good, plain]
    }

    /// Foreign files in the record folder, for the Other content section.
    @discardableResult
    static func seedOtherFiles(_ controller: CaptureController,
                               in root: URL) throws -> [URL] {
        let urls = [root.appendingPathComponent("A003_C012_0714XY.mov"),
                    root.appendingPathComponent("reference.png")]
        for url in urls { try Data([0x00]).write(to: url) }
        controller.otherFiles = urls
        controller.otherDurations[urls[0]] = 42
        return urls
    }

    /// A take in the player with markers on it. `playbackMarkers` is derived
    /// from the take list and the loaded URL, so both have to be seeded — one
    /// marker without a note (the editor falls back to "Marker %d") and one
    /// with.
    static func seedPlaybackWithMarkers(_ controller: CaptureController,
                                        in root: URL) throws {
        var take = ControllerFixtures.take(named: "TS_A001C03", in: root, clip: 3)
        take.markers = [
            TakeMarker(seconds: 1, timecodeText: "10:00:01:00", color: "red"),
            TakeMarker(seconds: 3.5, timecodeText: "10:00:03:12",
                       color: "green", note: "фокус ушёл"),
        ]
        try ControllerFixtures.placeholder(for: take)
        controller.takes = [take]
        controller.playbackURL = take.url
    }

    /// A CinemaDNG "clip": one .dng file is enough for `RawPlayerModel` to
    /// open — the frame is never decoded while the transport is only measured,
    /// and the size and rate fall back to 1920x1080/24 when the file is not
    /// really a DNG.
    static func rawPlayer(in root: URL) throws -> RawPlayerModel {
        let folder = root.appendingPathComponent("clip.dng-sequence")
        try FileManager.default.createDirectory(at: folder,
                                               withIntermediateDirectories: true)
        try Data("frame".utf8)
            .write(to: folder.appendingPathComponent("frame_000001.dng"))
        var error: String?
        return try #require(RawPlayerModel(url: folder, error: &error),
                            "RawPlayerModel refused a DNG folder: \(error ?? "-")")
    }

    /// VANC packet stats, including a DID the describer does not know — that is
    /// what puts the localized "Unknown" into the table.
    static let vancStats: [VancPacketStat] = [
        VancPacketStat(did: 0x60, sdid: 0x60, count: 1250, lastLine: 9,
                       lastDataHex: "60 60 10 00 00 00"),
        VancPacketStat(did: 0x51, sdid: 0x53, count: 40, lastLine: 13,
                       lastDataHex: "51 53 08 01 02 03"),
        VancPacketStat(did: 0x7F, sdid: 0x01, count: 3, lastLine: 21,
                       lastDataHex: "7F 01 04 AA BB"),
    ]

    /// Sixteen embedded channels at plausible levels — the normal SDI embed,
    /// and what the meters and the big audio panel are sized for.
    static func seedAudioLevels(_ controller: CaptureController, count: Int = 16) {
        controller.live.audioLevels = (0..<count).map { -Float($0) * 2 - 8 }
    }
}
