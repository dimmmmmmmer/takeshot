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
//
// SIZES ARE PORTABLE; INK IS NOT. Everything above answers with AppKit's own
// text and control measurement and says the same thing on any machine. The
// rasterizing calls below — brightColumns, drawnBounds, horizontalDetail,
// meanBrightness — answer what THIS host actually drew, and two things about
// that differ from machine to machine. A suite went red on both at once when
// CI moved to a runner two OS releases behind the development Mac:
//
//   * the backing scale. 2x on a Retina Mac, 1x on a runner with no display.
//     Absolute pixel counts are not comparable across it, and neither is a
//     RATIO between two renders whose scale factors differ — the interpolator
//     does a different job at each. `backingScale` is how a test that has to
//     compare two renders sizes its boxes in device pixels instead of points.
//   * whether an AppKit CONTROL draws to the edges of its bounds. It does not
//     on every release — see `controlInkFillsItsBounds`. An ink margin read off
//     a segmented picker is a fact about that release, not about the layout.
//
// Ink that SwiftUI draws ITSELF — a filled Color, a Path, a scope trace — is
// subject to neither and needs no gate.

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

    /// Build the view's tree at an exact size, for a test that needs the tree
    /// to EXIST rather than to be measured — an `NSViewRepresentable` registers
    /// itself in `makeNSView`, and nothing about that is a size.
    ///
    /// Separate from `laidOutSize` on purpose. That function used to do this by
    /// accident — it hosted the view and handed its own argument back — so
    /// tests counting mounts and tests asserting a size were leaning on the
    /// same call for two different reasons, and only one of them was working.
    static func mountTree(_ view: some View, in size: CGSize) {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        withExtendedLifetime(host) {}
    }

    /// What the view ASKS FOR when it is offered exactly `size`. Used for "an
    /// overlay must not stretch its host": the answer has to stay the size that
    /// was offered, and content that cannot compress answers with more.
    ///
    /// **This used to return its own argument.** It set `host.frame` and then
    /// read `host.frame.size` back — an `NSHostingView` handed an explicit
    /// frame keeps it, and `layoutSubtreeIfNeeded()` lays out the SUBVIEWS
    /// rather than resizing the host. So every "must not stretch" assertion in
    /// this suite was `size == size` and could not fail: a badge overlay, an
    /// assist overlay, a teach box, a sync-play grid or a slate face that
    /// genuinely blew its host out would have passed.
    ///
    /// `sizeThatFits` is the question that has an answer. It is the same call
    /// `size(_:proposedWidth:proposedHeight:)` makes, and the note there — that
    /// content which cannot compress answers with MORE than the proposal — is
    /// exactly the signal these callers wanted.
    static func laidOutSize(_ view: some View, in size: CGSize) -> CGSize {
        let controller = NSHostingController(rootView: AnyView(view))
        // The tree has to exist first: `sizeThatFits` on a controller whose
        // view was never loaded hands the proposal straight back — which is the
        // failure this function is being rescued from.
        _ = controller.view
        return controller.sizeThatFits(in: size)
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
    ///
    /// `body` is `@MainActor` rather than nonisolated, and has to be: an
    /// unisolated closure returning an unconstrained `T` sends that value back
    /// across an isolation boundary, which the macOS 15 SDK rejects and the
    /// macOS 26 one permits. Every caller is already a main-actor test looking
    /// at a hosted view, so this states where the work was happening anyway.
    static func mounted<T>(_ view: some View,
                           in size: CGSize = CGSize(width: 1280, height: 720),
                           _ body: @MainActor () async throws -> T)
        async rethrows -> T {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(host) {} }
        return try await body()
    }

    /// Device pixels per point this host rasterizes at: 2 on a Retina Mac, 1 on
    /// a runner with no display attached.
    ///
    /// A test that compares two RENDERS has to size its boxes through this, or
    /// the two are scaled differently on the two machines and the comparison
    /// measures the interpolator rather than the drawing.
    static func backingScale(
        in size: CGSize = CGSize(width: 200, height: 100)) -> Double {
        let host = NSHostingView(rootView: AnyView(Color.clear))
        host.frame = CGRect(origin: .zero, size: size)
        guard size.width > 0,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return 1 }
        return Double(rep.pixelsWide) / Double(size.width)
    }

    /// Whether an ink measurement of an AppKit CONTROL can be held against the
    /// frame the layout gave it.
    ///
    /// A segmented control does not draw to the edges of its bounds before
    /// macOS 26: AppKit insets the cell to leave room for a focus ring, and
    /// only the SELECTED segment carries a background bright enough to read
    /// back at all. "The picker's ink reaches its right edge" is therefore
    /// false on macOS 15 and says nothing about whether the picker was pinned
    /// to a frame wider than itself — which is the thing worth guarding.
    ///
    /// Assertions that compare control ink against a frame or a margin go
    /// behind this, with the reason written at the call site; the layout facts
    /// around them stay ungated. A runtime check and not `#available`: this is
    /// about how a release DRAWS, not about an API that appeared in it.
    static let controlInkFillsItsBounds = ProcessInfo.processInfo
        .isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26,
                                                         minorVersion: 0,
                                                         patchVersion: 0))

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

    /// The bounding box, in points, of everything the view drew above `floor`.
    ///
    /// `brightColumns` answers "is it there"; this answers "does it stay inside
    /// the space it was given". A scope that runs from the first row of its
    /// canvas to the last has nothing left between the measurement and the
    /// frame around it, which is what the operator reported the vectorscope
    /// doing. Nil when the view drew nothing.
    static func drawnBounds(_ view: some View, in size: CGSize,
                            floor: Double = 0.06) -> CGRect? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = Double(max(1, rep.pixelsWide / max(1, Int(size.width))))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.genericRGB) else { continue }
                let peak = max(Double(color.redComponent),
                               max(Double(color.greenComponent),
                                   Double(color.blueComponent)))
                guard peak > floor else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                      width: Double(maxX - minX + 1) / scale,
                      height: Double(maxY - minY + 1) / scale)
    }

    /// How much horizontal detail survived to the screen: the mean absolute
    /// step between horizontally adjacent device pixels, over the mean level.
    ///
    /// The number that separates a trace drawn near its own resolution from one
    /// the interpolator has stretched. A waveform and a parade draw the SAME
    /// density map — the parade squeezes it into a third of the box and the
    /// waveform spreads it over all of it — so this is the only way from a test
    /// to see the difference the operator was reporting.
    static func horizontalDetail(_ view: some View, in size: CGSize) -> Double {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var steps = 0.0
        var total = 0.0
        // every third row: this is an average over a few hundred thousand
        // pixels either way, and the answer moves in the fourth decimal
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            var previous: Double?
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.genericRGB) else { continue }
                let value = 0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
                if let previous { steps += abs(value - previous) }
                total += value
                previous = value
            }
        }
        return total > 0 ? steps / total : 0
    }

    /// Mean brightness of a rendered view, 0…1.
    ///
    /// The question `brightColumns` cannot answer: "does this control reach
    /// this drawing AT ALL". A graticule that ignores the brightness slider
    /// renders byte-identically at both ends of it, and the only way to see
    /// that from a test is to rasterize it twice and compare. Every scope's
    /// chrome used to have its own hard-coded opacities, which is exactly how
    /// the histogram ended up deaf to a control the operator expected to work
    /// on all four.
    static func meanBrightness(_ view: some View, in size: CGSize) -> Double {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var total = 0.0
        var counted = 0
        // every fourth pixel each way: this is a comparison between two
        // renders, and a quarter of a megapixel says the same thing as all
        // of it for a quarter of the wall time
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.genericRGB) else { continue }
                total += Double(color.brightnessComponent)
                counted += 1
            }
        }
        return counted > 0 ? total / Double(counted) : 0
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
    /// `rethrows` so a caller may `#require` inside it: the restore is a
    /// `defer`, so a body that throws still leaves the language as it found it
    /// — which is the whole reason this helper exists.
    static func withLanguage<T>(_ language: AppLanguage,
                                _ body: () throws -> T) rethrows -> T {
        let previous = L10n.current
        L10n.apply(language)
        defer { L10n.apply(previous) }
        return try body()
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
                    _ body: @MainActor () async throws -> T)
        async rethrows -> T {
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

/// One source shape a tile can be handed, and the name a failure reports it by.
struct ThumbnailAspect {
    let name: String
    let width: Int
    let height: Int
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
///
/// Main-actor because that is where the numbers come from: several of these
/// read a constant off a production view, and a view's constants belong to the
/// actor the view does.
@MainActor
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

    /// Foreign files in the record folder, for the Other content section: one
    /// clip and one still, each carrying the fact its cell shows — a length for
    /// the clip, a pixel size for the photo (owner item 27).
    @discardableResult
    static func seedOtherFiles(_ controller: CaptureController,
                               in root: URL) throws -> [URL] {
        let urls = [root.appendingPathComponent("A003_C012_0714XY.mov"),
                    root.appendingPathComponent("reference.png")]
        for url in urls { try Data([0x00]).write(to: url) }
        controller.otherFiles = urls
        controller.otherDurations[urls[0]] = 42
        controller.otherPixelSizes[urls[1]] = CGSize(width: 6000, height: 4000)
        return urls
    }

    /// A decoded thumbnail of a given pixel size, as the panel would hold one.
    ///
    /// The aspect is the whole point: a tile has to be 16:9 whatever it is
    /// handed, and a portrait frame is the shape that used to blow the tile up
    /// (owner item 26). Drawn rather than empty so the render path is the real
    /// one — an NSImage with no representation is not resized by SwiftUI.
    static func thumbnail(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// The aspect ratios a record folder really produces: broadcast 16:9, a
    /// phone shot upright, a square social crop and a scope-cropped wide.
    static let thumbnailAspects = [
        ThumbnailAspect(name: "16:9", width: 1920, height: 1080),
        ThumbnailAspect(name: "portrait", width: 1080, height: 1920),
        ThumbnailAspect(name: "square", width: 1080, height: 1080),
        ThumbnailAspect(name: "2.39:1", width: 2048, height: 858),
    ]

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
