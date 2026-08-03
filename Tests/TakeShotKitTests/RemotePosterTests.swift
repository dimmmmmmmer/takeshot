import AppKit
import CaptureCore
import Foundation
import ImageIO
import Testing

@testable import TakeShotKit

/// The last take on the phone: the JPEG the poster endpoint serves, who is
/// allowed to fetch it, and the two status fields the page watches to know when
/// to fetch it again.
///
/// The bytes are checked as an image rather than for length. A "poster" that is
/// four bytes of an error page still satisfies "something came back", and on a
/// phone it is a broken-image icon nobody can debug from a set.
/// Shared by the two poster suites: a stand-in thumbnail, and what the bytes
/// that come back actually are.
enum PosterFixtures {
    /// A decoded take thumbnail, standing in for one the controller made.
    ///
    /// It has an alpha channel on purpose: that is what a still or a RAW bridge
    /// hands back, and JPEG cannot represent it — the encoder has to redraw
    /// rather than re-wrap. It also has some structure in it, because a flat
    /// frame compresses to almost nothing and would satisfy a size assertion by
    /// accident.
    static func picture(width: Int, height: Int) throws -> NSImage {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let canvas = context.cgContext
        canvas.setFillColor(NSColor.white.cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setFillColor(NSColor.black.cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        canvas.setFillColor(NSColor.systemRed.cgColor)
        canvas.fill(CGRect(x: width / 4, y: height / 4,
                           width: width / 3, height: height / 3))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// What the bytes actually are: the container type they declare and the
    /// size they decode to.
    struct DecodedImage {
        var type: String
        var width: Int
        var height: Int
    }

    /// The bytes read back through ImageIO. Asserting on this rather than on a
    /// byte count is the difference between "a poster arrived" and "an error
    /// page arrived with image/jpeg on it".
    static func decoded(_ data: Data) throws -> DecodedImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil),
                                  "the bytes are not an image at all")
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return DecodedImage(
            type: try #require(CGImageSourceGetType(source) as String?),
            width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }
}

@Suite @MainActor struct RemotePosterTests {
    private func picture(width: Int, height: Int) throws -> NSImage {
        try PosterFixtures.picture(width: width, height: height)
    }

    private func decoded(_ data: Data) throws -> PosterFixtures.DecodedImage {
        try PosterFixtures.decoded(data)
    }

    // MARK: - the encoder

    @Test func aPosterIsAJPEGThatDecodesBackAtItsOwnSize() throws {
        let data = try #require(
            RemotePoster.jpeg(from: try picture(width: 256, height: 144)))
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF],
                "no JPEG start-of-image marker")
        let image = try decoded(data)
        #expect(image.type == "public.jpeg")
        #expect(image.width == 256)
        #expect(image.height == 144)
    }

    /// The cap is on the longest edge and keeps the aspect: a poster stretched
    /// to a square would have the director comparing the wrong shapes.
    @Test func anOversizedFrameIsCappedOnItsLongestEdge() throws {
        let data = try #require(
            RemotePoster.jpeg(from: try picture(width: 1200, height: 675)))
        let image = try decoded(data)
        #expect(image.width == Int(RemotePoster.maximumEdge))
        #expect(image.height == 360)
    }

    /// A frame already under the cap is not blown up to meet it.
    @Test func aSmallFrameIsLeftAtItsOwnSize() throws {
        let data = try #require(
            RemotePoster.jpeg(from: try picture(width: 96, height: 54)))
        let image = try decoded(data)
        #expect(image.width == 96)
        #expect(image.height == 54)
    }

    // MARK: - the endpoint

    @Test func theEndpointServesTheLastTakesFrame() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C20", clip: 20)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let answer = try await RemoteHarness.poster(port: port, pin: pin)
            #expect(answer.http.statusCode == 200)
            #expect(answer.http.value(forHTTPHeaderField: "Content-Type")
                == "image/jpeg")
            // A phone must never be handed the previous take out of its own
            // cache: the URL is the same one every take.
            #expect(answer.http.value(forHTTPHeaderField: "Cache-Control")
                == "no-store")
            let image = try decoded(answer.body)
            #expect(image.type == "public.jpeg")
            #expect(image.width == 256)
        }
    }

    /// The frame is production data — a set nobody has announced, a face under
    /// a wig — and it is behind the PIN for the same reason the timecode is.
    @Test func theWrongPINGetsNoFrame() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C24", clip: 24)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let refused = try await RemoteHarness.poster(
                port: port, pin: RemoteHarness.wrongPIN(besides: pin))
            #expect(refused.http.statusCode == 403)
            #expect(CGImageSourceCreateWithData(refused.body as CFData, nil)
                .flatMap { CGImageSourceGetType($0) } == nil,
                "a refused request still came back carrying an image")
        }
    }

    /// A PIN-less fetch is the shape a scanner tries first, and it must land
    /// exactly where a wrong code does.
    @Test func aFetchWithNoPINAtAllIsRefused() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C25", clip: 25)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)
            let (port, _) = try await RemoteHarness.serve(controller)
            let url = try #require(URL(
                string: "http://127.0.0.1:\(port)\(RemotePage.posterPath)"))
            let (_, response) = try await RemoteHarness.session().data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
        }
    }

    /// A take finalizes and its frame is decoded after it: "not yet" is a real
    /// answer and the page is built around getting it. Asking is also what
    /// starts the decode, so the 404 sets up its own retry.
    @Test func aTakeWithNoDecodedFrameYetIsNotFound() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C26", clip: 26)
            #expect(controller.thumbnails[take.id] == nil)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let answer = try await RemoteHarness.poster(port: port, pin: pin)
            #expect(answer.http.statusCode == 404)
            let asked = await ControllerWait.until {
                controller.thumbnailsInFlight.contains(take.id)
                    || controller.thumbnails[take.id] != nil
            }
            #expect(asked, "the 404 did not start the decode it is waiting for")
        }
    }

    @Test func aDayWithNoTakesHasNoPoster() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.takes.isEmpty)
            let (port, pin) = try await RemoteHarness.serve(controller)
            let answer = try await RemoteHarness.poster(port: port, pin: pin)
            #expect(answer.http.statusCode == 404)
        }
    }

    // MARK: - what tells the page to fetch again

    /// The card is about the take that LANDED, and mid-take that is not the one
    /// the header names. One field cannot be both without the card captioning
    /// the previous take's picture with the name of the one being written.
    @Test func theStatusNamesTheLastTakeApartFromTheOneInProgress() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C27", clip: 27)
            let landed = controller.remoteStatus()
            #expect(landed.takeName == "A001C27")
            #expect(landed.lastTakeName == "A001C27")
            #expect(landed.lastTakeID == take.id.uuidString)

            controller.isRecording = true
            let rolling = controller.remoteStatus()
            #expect(rolling.takeName == controller.pendingTakeName)
            #expect(rolling.lastTakeName == "A001C27", """
                the card would caption the last take's frame with the name of \
                the take being written
                """)
            #expect(rolling.lastTakeID == take.id.uuidString)
        }
    }

    /// The id and not a count of takes: delete one and record another and the
    /// count is back where it was, which leaves a phone showing the poster of
    /// footage that is gone.
    @Test func theTakeIdMovesEvenWhenTheCountDoesNot() async throws {
        try await ControllerHarness.run { controller, root in
            try RemoteHarness.seedTake(controller, in: root, named: "A001C28",
                                       clip: 28)
            let first = controller.remoteStatus().lastTakeID
            try RemoteHarness.seedTake(controller, in: root, named: "A001C29",
                                       clip: 29)
            let second = controller.remoteStatus()

            #expect(controller.takes.count == 1, "the fixture replaced the list")
            #expect(!first.isEmpty)
            #expect(second.lastTakeID != first,
                    "the page has no way to tell the poster is stale")
            #expect(second.lastTakeName == "A001C29")
        }
    }

    /// The page fetches the poster with an `<img>`, and the route it builds and
    /// the route the server answers are the same constant. They used to be two
    /// string literals in two files, which fails as a card that is permanently
    /// "no frame yet" with nothing in any log.
    @Test func thePageIsGivenTheRouteAndTheFieldItWatches() throws {
        let html = try #require(String(bytes: RemotePage.html(), encoding: .utf8))
        #expect(html.contains("posterPath:\"\(RemotePage.posterPath)\""))
        #expect(html.contains("CFG.posterPath"),
                "the page was handed a route it does not use")
        #expect(html.contains("lastTakeId"),
                "the page never notices a new take landing")
        #expect(html.contains("lastTake"))
    }
}

/// The per-take posters the script supervisor's log draws (owner item 11).
///
/// Its own suite rather than more rows in `RemotePosterTests`: that one is
/// about the operator page's single card — the last take that landed — and
/// this is about a route that is asked for a take by name, thirty times on one
/// page load. The shared fixtures are `PosterFixtures`.
@Suite @MainActor struct RemoteRowPosterTests {
    private func picture(width: Int, height: Int) throws -> NSImage {
        try PosterFixtures.picture(width: width, height: height)
    }

    private func decoded(_ data: Data) throws -> PosterFixtures.DecodedImage {
        try PosterFixtures.decoded(data)
    }

    /// The script page draws a poster per row, so the route takes a take id and
    /// answers for THAT take — not for whichever one landed last, which is what
    /// a log of thirty rows would otherwise show thirty times.
    @Test func theEndpointServesTheTakeItIsAskedFor() async throws {
        try await ControllerHarness.run { controller, root in
            var takes: [Take] = []
            for clip in 30...31 {
                var take = ControllerFixtures.take(named: "A001C\(clip)",
                                                   in: root, clip: clip)
                try ControllerFixtures.placeholder(for: take)
                take.rating = .none
                takes.append(take)
            }
            controller.takes = takes
            // Two different SIZES, so the answer names itself: a route that
            // ignored the id would hand back the same picture twice.
            controller.thumbnails[takes[0].id] = try picture(width: 200,
                                                             height: 112)
            controller.thumbnails[takes[1].id] = try picture(width: 128,
                                                             height: 72)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let older = try await RemoteHarness.poster(
                port: port, pin: pin, take: takes[0].id.uuidString)
            #expect(older.http.statusCode == 200)
            #expect(try decoded(older.body).width == 200)

            let newer = try await RemoteHarness.poster(
                port: port, pin: pin, take: takes[1].id.uuidString)
            #expect(try decoded(newer.body).width == 128)

            // No id at all is still "the last take that landed" — the operator
            // page's card asks that way when it has no id yet.
            let last = try await RemoteHarness.poster(port: port, pin: pin)
            #expect(try decoded(last.body).width == 128)
        }
    }

    /// A row's thumbnail is production picture exactly as the status is, and it
    /// is behind the same four digits. An image route that answered without the
    /// PIN would be the whole day's footage in stills to anyone on the port.
    @Test func aRowsFrameNeedsThePINLikeEverythingElse() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C32", clip: 32)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let refused = try await RemoteHarness.poster(
                port: port, pin: RemoteHarness.wrongPIN(besides: pin),
                take: take.id.uuidString)
            #expect(refused.http.statusCode == 403)
            #expect(CGImageSourceCreateWithData(refused.body as CFData, nil)
                .flatMap { CGImageSourceGetType($0) } == nil,
                "a refused request still came back carrying an image")
        }
    }

    /// A take that is no longer in the list — deleted between the push and the
    /// tap — is a 404 and not somebody else's frame.
    @Test func anUnknownTakeIdIsNotAnswered() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C33", clip: 33)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)
            let (port, pin) = try await RemoteHarness.serve(controller)

            let answer = try await RemoteHarness.poster(
                port: port, pin: pin, take: UUID().uuidString)
            #expect(answer.http.statusCode == 404)
        }
    }

    /// Encoded once per take, not once per request: a page with a shift's worth
    /// of rows on it would otherwise put a JPEG pass per row on the MainActor,
    /// which is where the REC button lives.
    @Test func aTakesPosterIsEncodedOnceAndKept() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C34", clip: 34)
            controller.thumbnails[take.id] = try picture(width: 256, height: 144)

            let first = try #require(
                controller.remoteTakePoster(id: take.id.uuidString))
            #expect(controller.remotePosterJPEG[take.id] != nil)
            // The image behind it goes away; the bytes are still served.
            controller.thumbnails[take.id] = nil
            let second = try #require(
                controller.remoteTakePoster(id: take.id.uuidString))
            #expect(second == first)
        }
    }

    /// The payload carries the reference, so the page never builds the route
    /// itself — a page that assembled its own would break silently on the next
    /// rename, as a log of empty boxes.
    @Test func everyTakeLogRowCarriesItsThumbnailReference() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C35", clip: 35)
            let entry = try #require(controller.remoteTakeLog().entries.first)
            #expect(entry.poster.hasPrefix(RemotePage.posterPath))
            #expect(entry.poster.contains(take.id.uuidString))
            #expect(!entry.poster.contains("pin"),
                    "the code was baked into a reference the app pushes")

            let object = try #require(try JSONSerialization.jsonObject(
                with: Data(controller.remoteTakeLog().json.utf8))
                as? [String: Any])
            let rows = try #require(object["takes"] as? [[String: Any]])
            #expect(rows.first?["poster"] as? String == entry.poster)
        }
    }

    /// And the page reads it — with the PIN added on its side, one fetch at a
    /// time so a log's worth of images cannot eat the server's connection
    /// slots out from under the next phone's socket.
    @Test func theScriptPageDrawsRowsFromThatReference() throws {
        let html = try #require(String(bytes: RemotePage.scriptHTML(),
                                       encoding: .utf8))
        #expect(html.contains("row.posterURL"),
                "the page ignores the reference it is pushed")
        #expect(html.contains(#"row.posterURL + "&pin=""#),
                "the page fetches a row's frame without the code")
        #expect(html.contains("posterBusy"),
                "the page fetches every row's frame at once")
        #expect(html.contains("rowPoster"))
    }
}
