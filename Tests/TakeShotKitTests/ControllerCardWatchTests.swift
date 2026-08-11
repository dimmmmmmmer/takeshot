import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// A card that mounts must ASK, and must never copy itself.
///
/// That is the owner's one condition on the whole feature ("авто оффлоад супер,
/// но должен получить подтверждение от пользователя"), so most of what follows is
/// about the things that must NOT happen: no copy, no modal, no prompt during a
/// take, no second ask about a card already dealt with.
///
/// Never a real volume. `FakeVolumeWatch` reports synthetic mounts over scratch
/// directories the tests populate as fake cards — mounting a disk image per test
/// would need privileges no CI runner has and would leave a volume mounted behind
/// every failure.
/// Shared fixtures for the two suites below.
///
/// A namespace rather than methods on the suite because there are two of them
/// now — the watch itself, and the list of cards it has stopped asking about
/// (owner item 18) — and a fixture set that belongs to whichever suite happens
/// to be written first is how the second one ends up with a copy of it.
@MainActor
private enum CardFixture {
    static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-card-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return ControllerFixtures.resolved(url)
    }

    /// A card as a camera leaves it: a DCIM tree with two clips in it.
    static func makeCard(_ name: String) throws -> URL {
        let root = try Self.scratch(name)
        let dcim = root.appendingPathComponent("DCIM/100CANON")
        try FileManager.default.createDirectory(at: dcim,
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048)
            .write(to: dcim.appendingPathComponent("A001C001.MOV"))
        try Data(repeating: 9, count: 1024)
            .write(to: dcim.appendingPathComponent("A001C002.MOV"))
        return root
    }

    /// How many files are under a folder — the assertion that nothing was copied
    /// is made against this, not against a flag.
    static func fileCount(under root: URL) -> Int {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        for case let url as URL in enumerator ?? .init() {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// The controller under test, with a fake volume watch wired into it. The
    /// harness has already pointed the ledger at scratch — the real one lives in
    /// the operator's Application Support and decides which cards they get asked
    /// about at all.
    static func withWatch(
        configure: @escaping (inout CaptureSettings) -> Void = { _ in },
        _ body: (CaptureController, FakeVolumeWatch) async throws -> Void)
        async throws {
        let watch = FakeVolumeWatch()
        try await ControllerHarness.run(volumeWatch: watch,
                                        configure: configure) { controller, _ in
            try await body(controller, watch)
        }
    }

    /// Wait for the mount scan, which runs off the MainActor on purpose: a full
    /// card is a few hundred milliseconds of metadata I/O and the window must not
    /// stall for it.
    @discardableResult
    static func waitForOffer(_ controller: CaptureController) async -> Bool {
        await ControllerWait.until { controller.cardOffer != nil }
    }
}

@Suite @MainActor struct ControllerCardWatchTests {
    // MARK: - the rule: ask, never copy

    @Test func aMountedCardRaisesAPromptAndCopiesNothing() async throws {
        let card = try CardFixture.makeCard("ask")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            let before = CardFixture.fileCount(under: card)

            watch.mount(card, name: "A001")

            #expect(await CardFixture.waitForOffer(controller))
            let offer = try #require(controller.cardOffer)
            #expect(offer.files == 2)
            #expect(offer.bytes == 3072)
            #expect(offer.evidence == .cameraStructure("DCIM"))
            // …and the whole point: no run, no sheet, nothing written anywhere.
            #expect(!controller.offload.isRunning)
            #expect(!controller.offloadSheetPresented)
            #expect(controller.offload.source == nil)
            #expect(controller.offloadStatus == nil)
            #expect(CardFixture.fileCount(under: card) == before,
                    "the card was written to by a prompt")
        }
    }

    /// Accepting opens the ordinary sheet with the card in the source slot. The
    /// destinations stay the operator's — the app never guesses where footage
    /// lands.
    @Test func acceptingOpensTheSheetPreFilledWithThatCard() async throws {
        let card = try CardFixture.makeCard("accept")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))

            controller.acceptCardOffer()

            #expect(controller.offloadSheetPresented)
            #expect(controller.offload.source == card)
            #expect(controller.cardOffer == nil)
            #expect(!controller.offload.isRunning, "it started copying by itself")
        }
    }

    @Test func ignoreDismissesTheCardForThisSessionOnly() async throws {
        let card = try CardFixture.makeCard("ignore")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))

            controller.ignoreCardOffer()
            #expect(controller.cardOffer == nil)

            // the same card, plugged in again during this session
            watch.mount(card, name: "A001")
            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
            // …and nothing was written down, so the next launch asks again
            #expect(controller.offloadedCards.cards.isEmpty)
        }
    }

    /// Never is the persistent one, and it holds whatever gets shot onto the card
    /// afterwards.
    @Test func neverSilencesTheCardForGood() async throws {
        let card = try CardFixture.makeCard("never")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            let key = try #require(controller.cardOffer?.key)

            controller.neverOfferCardAgain()

            let record = try #require(controller.offloadedCards.record(for: key))
            #expect(record.suppressed)
            #expect(record.fingerprint == nil, "a Never must not depend on content")
            // it survives a relaunch: a fresh ledger over the same file
            let reloaded = OffloadedCardLedger()
            reloaded.fileURL = controller.offloadedCards.fileURL
            #expect(reloaded.record(for: key)?.suppressed == true)
            // …and even with new footage on it, the card stays quiet
            try Data(repeating: 3, count: 4096).write(
                to: card.appendingPathComponent("DCIM/100CANON/A001C003.MOV"))
            watch.mount(card, name: "A001")
            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    // MARK: - never re-offer, but notice new footage

    @Test func anOffloadedCardIsNotOfferedAgain() async throws {
        let card = try CardFixture.makeCard("settled")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            let candidate = try #require(controller.cardOffer)
            controller.offloadedCards.markOffloaded(candidate)
            controller.cardOffer = nil

            watch.mount(card, name: "A001")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// …but a card that has been shot on since IS offered again. That is the
    /// whole reason the ledger stores a fingerprint beside the key.
    @Test func theSameCardWithOneMoreFileIsOfferedAgain() async throws {
        let card = try CardFixture.makeCard("grown")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            controller.offloadedCards.markOffloaded(try #require(controller.cardOffer))
            controller.cardOffer = nil

            try Data(repeating: 5, count: 512).write(
                to: card.appendingPathComponent("DCIM/100CANON/A001C003.MOV"))
            watch.mount(card, name: "A001")

            #expect(await CardFixture.waitForOffer(controller))
            #expect(controller.cardOffer?.files == 3)
        }
    }

    /// Only a run that verified end to end settles a card. A stopped or broken
    /// one leaves it exactly as unasked-about as it was — that card is precisely
    /// the one nobody should assume is copied.
    @Test func onlyAVerifiedRunSettlesTheCard() async throws {
        let card = try CardFixture.makeCard("verified")
        let destination = try CardFixture.scratch("verified-dst")
        defer {
            try? FileManager.default.removeItem(at: card)
            try? FileManager.default.removeItem(at: destination)
        }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            let key = try #require(controller.cardOffer?.key)
            controller.acceptCardOffer()
            controller.offload.addDestination(destination)

            controller.offload.start()
            #expect(await ControllerWait.untilWritten {
                controller.offload.report != nil
            })

            #expect(try #require(controller.offload.report).isFullyVerified)
            #expect(controller.offloadedCards.record(for: key)?.suppressed == false)
            #expect(controller.offloadedCards.record(for: key)?.fingerprint
                == CardFingerprint(files: 2, bytes: 3072))
        }
    }

    // MARK: - never during a take

    @Test func aMountDuringRecordingWaitsForTheTakeToClose() async throws {
        let card = try CardFixture.makeCard("mid-take")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            controller.isRecording = true

            watch.mount(card, name: "A001")
            // give the scan every chance to land while the take is still open
            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
            #expect(await ControllerWait.until {
                !controller.deferredCardOffers.isEmpty
            }, "the card was dropped instead of queued")

            controller.isRecording = false
            controller.drainDeferredCardOffers()

            #expect(controller.cardOffer != nil)
            #expect(controller.deferredCardOffers.isEmpty)
        }
    }

    // MARK: - volumes that are never cards

    @Test func theBootVolumeNeverPrompts() async throws {
        try await CardFixture.withWatch { controller, watch in
            watch.mount(URL(fileURLWithPath: "/"), name: "Macintosh HD")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// The app's own destination disk: offering to copy a card OFF the disk the
    /// copies land on is the one wrong guess that costs more than a click.
    @Test func theDestinationVolumeNeverPrompts() async throws {
        let card = try CardFixture.makeCard("own-disk")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            // as if the record folder were a folder on this very volume
            controller.settings.capture.destinationPath =
                card.appendingPathComponent("Dailies").path
            #expect(controller.isExcludedVolume(
                MountedVolume(url: card, name: "A001")))

            watch.mount(card, name: "A001")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// A destination that is really THERE speaks for its volume: the disk the
    /// copies land on is not a card to copy.
    ///
    /// The folder is created, which is the whole difference from the test below
    /// it: a destination the operator picked through a file panel exists on the
    /// disk it was picked on. This fixture used to name a folder that had never
    /// been created, which passed for the wrong reason.
    @Test func aSavedOffloadDestinationNeverPrompts() async throws {
        let card = try CardFixture.makeCard("saved-dst")
        defer { try? FileManager.default.removeItem(at: card) }
        let dit = card.appendingPathComponent("DIT")
        try FileManager.default.createDirectory(at: dit,
                                                withIntermediateDirectories: true)
        let rig: (inout CaptureSettings) -> Void = { [dit] in
            $0.offload.destinationPaths = [dit.path]
        }
        try await CardFixture.withWatch(configure: rig) { controller, watch in
            #expect(controller.isExcludedVolume(
                MountedVolume(url: card, name: "DAILIES_SSD")))
            #expect(controller.ownFolder(on: MountedVolume(url: card,
                                                          name: "DAILIES_SSD"))?
                .path == dit.path,
                    "the exclusion could not say which folder caused it")
            watch.mount(card, name: "DAILIES_SSD")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// …and a destination that is GONE speaks for nothing.
    ///
    /// This is the half that cost footage. `offload.destinationPaths` could
    /// never be cleared (see the offload suite), and `ownFolders` matched it by
    /// path alone — so a retired `/Volumes/Untitled/DIT` excluded every future
    /// volume that macOS happened to mount at `/Volumes/Untitled`. A camera card
    /// arriving at that mount point was not scanned, not offered, and not
    /// logged: the app looked like it had simply stopped noticing cards.
    ///
    /// The card here is a real one — the same fixture every other test in this
    /// suite offers — with a saved destination naming a folder ON it that does
    /// not exist. Existence is the discriminator: on the SSD the path was picked
    /// on it is there, and on the card that inherited the mount point it is not.
    @Test func aCardIsStillOfferedWhereARetiredDestinationOnceSat() async throws {
        let card = try CardFixture.makeCard("inherited-mount")
        defer { try? FileManager.default.removeItem(at: card) }
        let retired = card.appendingPathComponent("DIT")
        let rig: (inout CaptureSettings) -> Void = { [retired] in
            $0.offload.destinationPaths = [retired.path]
        }
        try await CardFixture.withWatch(configure: rig) { controller, watch in
            let volume = MountedVolume(url: card, name: "Untitled")
            #expect(controller.ownFolder(on: volume) == nil,
                    "a destination that is not there still claimed the volume")
            #expect(!controller.isExcludedVolume(volume),
                    "the card was excluded by a destination that no longer exists")

            watch.mount(card, name: "Untitled")

            #expect(await CardFixture.waitForOffer(controller),
                    "the card was silently ignored")
            #expect(controller.cardOffer?.files == 2)
            // The setting is untouched — this is about what it MEANS for a
            // volume, not about deleting the operator's rig behind their back.
            #expect(controller.settings.offload.destinationPaths == [retired.path])
        }
    }

    // MARK: - the setting

    @Test func theToggleOffSuppressesEverything() async throws {
        let card = try CardFixture.makeCard("off")
        defer { try? FileManager.default.removeItem(at: card) }
        let off: (inout CaptureSettings) -> Void = { $0.offload.offerMountedCards = false }
        try await CardFixture.withWatch(configure: off) { controller, watch in
            #expect(!controller.offersMountedCards)
            #expect(!watch.isRunning, "the observers were installed anyway")

            watch.mount(card, name: "A001")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
            #expect(controller.deferredCardOffers.isEmpty)
        }
    }

    /// Turning it off mid-session takes the observers down and clears whatever is
    /// already on screen — a switch that leaves the last prompt up has not been
    /// turned off as far as the operator is concerned.
    @Test func turningTheToggleOffClearsAPromptAlreadyUp() async throws {
        let card = try CardFixture.makeCard("toggle")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            #expect(watch.isRunning)

            controller.settings.offload.offerMountedCards = false

            #expect(controller.cardOffer == nil)
            #expect(!watch.isRunning)
        }
    }

    // MARK: - unmount

    @Test func pullingTheCardTakesItsPromptWithIt() async throws {
        let card = try CardFixture.makeCard("pulled")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))

            watch.unmount(card)

            #expect(controller.cardOffer == nil)
        }
    }
}

/// Recognition on its own: what counts as camera media and what does not.
@Suite struct CardScanTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-scan-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in root: URL, bytes: Int = 16) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    /// Every layout a DIT actually meets. A structure match is the strong signal
    /// — nothing but a camera writes `XDROOT`.
    @Test(arguments: ["DCIM/A/x.mov", "XDROOT/Clip/x.mxf", "BPAV/x.mp4",
                      "M4ROOT/CLIP/x.mxf", "CLIPS/x.braw", "CONTENTS/VIDEO/x.mxf",
                      "PRIVATE/AVCHD/BDMV/STREAM/x.mts"])
    func aKnownCameraLayoutIsRecognised(path: String) throws {
        let root = try scratch("layout")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(path, in: root)

        let card = try #require(CardScan.inspect(
            MountedVolume(url: root, name: "CARD")))
        guard case .cameraStructure = card.evidence else {
            Issue.record("recognised as \(card.evidence), not a camera layout")
            return
        }
        #expect(card.files == 1)
    }

    /// `PRIVATE` alone proves nothing — plenty of ordinary disks have one, and
    /// only what is INSIDE it makes it a camcorder card.
    @Test func abarePrivateFolderIsNotACard() throws {
        let root = try scratch("private")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("PRIVATE/notes.txt", in: root)

        #expect(CardScan.inspect(MountedVolume(url: root, name: "STICK")) == nil)
    }

    /// A USB stick with a couple of MP4s is a maybe: offered, with the reason
    /// saying exactly why so the operator can judge.
    @Test func aRemovableDiskWithVideoIsAMaybe() throws {
        let root = try scratch("stick")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("holiday.mp4", in: root)
        try write("notes.txt", in: root)

        let card = try #require(CardScan.inspect(MountedVolume(
            url: root, name: "USB", isRemovable: true)))
        #expect(card.evidence == .detachableVideo(1))
        #expect(card.files == 2, "the fingerprint must cover the whole card")
    }

    /// …and the same files on a disk that cannot be unplugged are not a card at
    /// all. An internal scratch disk full of MP4s must never prompt.
    @Test func videoOnAFixedDiskIsNotACard() throws {
        let root = try scratch("fixed")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("holiday.mp4", in: root)

        #expect(CardScan.inspect(MountedVolume(url: root, name: "SCRATCH")) == nil)
    }

    /// A Time Machine disk is a no, even though it is removable and full of
    /// files. So is a disk that already holds offloads — that is a DESTINATION.
    @Test(arguments: ["Backups.backupdb/x", ".com.apple.timemachine.supported",
                      "ascmhl/x.mhl"])
    func aBackupOrDestinationDiskIsRefused(marker: String) throws {
        let root = try scratch("refused")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(marker, in: root)
        try write("DCIM/A/x.mov", in: root)

        #expect(CardScan.inspect(MountedVolume(
            url: root, name: "TM", isRemovable: true)) == nil)
    }

    /// A freshly formatted card has the structure and nothing to copy.
    @Test func anEmptyCardIsNotOffered() throws {
        let root = try scratch("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("DCIM"),
            withIntermediateDirectories: true)

        #expect(CardScan.inspect(MountedVolume(
            url: root, name: "BLANK", isRemovable: true)) == nil)
    }

    @Test func aNetworkShareIsNeverWalked() throws {
        let root = try scratch("share")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("DCIM/A/x.mov", in: root)

        #expect(CardScan.inspect(MountedVolume(
            url: root, name: "NAS", isLocal: false)) == nil)
    }

    /// The volume UUID is the identity when there is one: the same card in a
    /// different reader mounts at a different path and is still that card.
    @Test func theKeyPrefersTheVolumeUUID() throws {
        let root = try scratch("key")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("DCIM/A/x.mov", in: root)
        let volume = MountedVolume(url: root, name: "CARD", uuid: "UUID-1")

        #expect(try #require(CardScan.inspect(volume)).key == "UUID-1")
        #expect(try #require(CardScan.inspect(
            MountedVolume(url: root, name: "CARD"))).key == root.standardized.path)
    }
}

/// The cards the app has stopped asking about, as the offload sheet lists them
/// (owner item 18).
///
/// Its own suite because it is a different question from the one above: the
/// watch decides whether to ASK, this decides what the operator can see and
/// undo about the asking. Everything is asserted through the watch rather than
/// through the store — a ledger row disappearing is not the feature, a card
/// prompting again is.
@Suite @MainActor struct ControllerCardLedgerTests {
    /// Both kinds of entry reach the ledger the list draws from, and each says
    /// which of the two decisions it was — they are not interchangeable: a
    /// copied card comes back the moment it has been shot on again, a silenced
    /// one never does.
    @Test func theLedgerRecordsBothKindsOfDecision() async throws {
        let copied = try CardFixture.makeCard("ledger-copied")
        let silenced = try CardFixture.makeCard("ledger-never")
        defer {
            try? FileManager.default.removeItem(at: copied)
            try? FileManager.default.removeItem(at: silenced)
        }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(copied, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            controller.offloadedCards.markOffloaded(
                try #require(controller.cardOffer))
            controller.cardOffer = nil

            watch.mount(silenced, name: "DIT_STICK")
            #expect(await CardFixture.waitForOffer(controller))
            controller.neverOfferCardAgain()

            #expect(controller.offloadedCards.cards.count == 2)
            let names = Set(controller.offloadedCards.cards.map(\.name))
            #expect(names == ["A001", "DIT_STICK"])
            let kinds = Set(controller.offloadedCards.cards.map(\.suppressed))
            #expect(kinds == [true, false], "both kinds must be distinguishable")
        }
    }

    /// Clearing a row of that list makes the card promptable again — asserted
    /// through the watch, because the store forgetting it is only half of the
    /// job. `neverOfferCardAgain` also writes the key into this session's
    /// `ignoredCardKeys`, and a forget that cleared the file alone would leave
    /// the card silent until the next launch: exactly the "is this broken?"
    /// the list exists to answer.
    @Test func forgettingARememberedCardMakesItPromptAgain() async throws {
        let card = try CardFixture.makeCard("forget")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
            let key = try #require(controller.cardOffer?.key)
            controller.neverOfferCardAgain()
            watch.mount(card, name: "A001")
            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))),
                    "a silenced card prompted before it was forgotten")

            controller.forgetOffloadedCard(key)

            #expect(controller.offloadedCards.record(for: key) == nil)
            // still in the reader, so it is asked about now rather than at the
            // next mount — and it prompts on a fresh mount too
            #expect(controller.cardOffer?.key == key)
            controller.ignoreCardOffer()
            controller.ignoredCardKeys.remove(key)
            watch.mount(card, name: "A001")
            #expect(await CardFixture.waitForOffer(controller))
        }
    }
}
