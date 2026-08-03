import CaptureCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TakeShotKit

/// The four browse dialogs: the record folder, the look importer, the chroma
/// plate, and the offload sheet's folder picker.
///
/// All four go through `FilePanel`, so the suite can answer them instead of
/// stopping on `NSOpenPanel.runModal()`. Two things are worth holding here and
/// neither is reachable any other way: WHAT each dialog offers — a folder browser
/// that also offers files sends the operator picking a movie as a record
/// destination — and that Cancel changes nothing, which is the state the app is
/// left in most times one of these opens.
@Suite @MainActor struct ControllerPickerTests {
    /// Choosing a record folder adopts it, and the library is reset for it: the
    /// previous day's takes belong to the previous folder.
    @Test func choosingARecordFolderAdoptsIt() async throws {
        let elsewhere = try MediaFixtures.makeDirectory("picker-destination")
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        try await ControllerHarness.run { controller, root in
            var take = ControllerFixtures.take(named: "A001C001", in: root)
            take.rating = .good
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]

            try await FakeFilePanel.installed(opening: [[elsewhere]]) { panel in
                controller.chooseDestinationFolder()

                #expect(controller.settings.destinationPath == elsewhere.path)
                let request = try #require(panel.openRequests.first)
                #expect(request.directories, "the folder browser offered no folders")
                #expect(!request.files,
                        "the record-folder browser offered files to pick")
                #expect(request.createDirectories,
                        "the operator could not make a folder for the day")
                #expect(request.directory == root,
                        "the browser opened somewhere other than the current folder")
                #expect(controller.takes.isEmpty,
                        "the previous folder's takes followed the operator")
            }
        }
    }

    /// Cancelling leaves the record folder alone. This is a destructive dialog —
    /// adopting a folder resets the library — so a cancel that fell through would
    /// clear the day's panel for nothing.
    @Test func cancellingTheFolderBrowserChangesNothing() async throws {
        try await ControllerHarness.run { controller, root in
            var take = ControllerFixtures.take(named: "A001C001", in: root)
            try ControllerFixtures.placeholder(for: take)
            take.rating = .good
            controller.takes = [take]

            try await FakeFilePanel.installed { panel in
                controller.chooseDestinationFolder()

                #expect(panel.openRequests.count == 1)
                #expect(controller.settings.destinationPath == root.path)
                #expect(controller.takes.count == 1)
            }
        }
    }

    /// The look importer takes several files at once — a DIT hands over a folder
    /// of grades, not one — and filters on the look extensions the app can read.
    @Test func theLookImporterTakesSeveralFilesAndFiltersOnLooks() async throws {
        let media = try MediaFixtures.makeDirectory("picker-looks")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = media.appendingPathComponent("LUTs")
            controller.resolveLUTDirectory = media.appendingPathComponent("Resolve")
            let first = try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("warm.cube"))
            let second = try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("cool.cube"))

            try await FakeFilePanel.installed(opening: [[first, second]]) { panel in
                controller.importLUT()

                #expect(controller.availableLUTs.map(\.fileName).sorted()
                            == ["cool.cube", "warm.cube"])
                let request = try #require(panel.openRequests.first)
                #expect(request.multiple, "only one look could be imported at a time")
                let offered = request.contentTypes
                    .compactMap(\.preferredFilenameExtension)
                #expect(offered.contains("cube"),
                        "the importer did not offer .cube files: \(offered)")
                #expect(!request.directories)
            }
        }
    }

    /// Cancelling the look importer imports nothing. `adoptLooks` creates the
    /// library folder and copies as it goes, so a cancel reaching it would be a
    /// visible no-op with real side effects.
    @Test func cancellingTheLookImporterImportsNothing() async throws {
        let media = try MediaFixtures.makeDirectory("picker-looks-cancel")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = media.appendingPathComponent("LUTs")
            controller.resolveLUTDirectory = media.appendingPathComponent("Resolve")
            // whatever the library already held, unchanged is the assertion —
            // the app ships a look, so "empty" would be a fact about the fixture
            let before = controller.availableLUTs.map(\.fileName)

            try await FakeFilePanel.installed { panel in
                controller.importLUT()

                #expect(panel.openRequests.count == 1)
                #expect(controller.availableLUTs.map(\.fileName) == before)
                #expect(!FileManager.default.fileExists(
                    atPath: controller.lutsDirectory.path),
                        "a cancelled import created the library folder")
            }
        }
    }

    /// The chroma plate picker offers stills AND clips: the plate is a picture
    /// either way, and a unit whose plate arrived as a QuickTime should not have
    /// to export a frame of it first.
    @Test func theChromaPlatePickerOffersStillsAndClips() async throws {
        let media = try MediaFixtures.makeDirectory("picker-plate")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let plate = try ControllerFixtures.writePNG(
                at: media.appendingPathComponent("plate.png"), side: 32)

            try await FakeFilePanel.installed(opening: [[plate]]) { panel in
                controller.chooseChromaBackgroundImage()

                #expect(controller.settings.chromaKeyBackgroundImagePath
                            == plate.path)
                let request = try #require(panel.openRequests.first)
                #expect(!request.multiple, "the plate picker took several files")
                #expect(!request.directories)
                #expect(request.message == L("chroma_choose_image"))
                let offered = Set(request.contentTypes
                    .compactMap(\.preferredFilenameExtension))
                #expect(offered.contains("png"), "no still format was offered")
                #expect(offered.contains("mov"), "no clip format was offered")
            }
            // the decode runs off the main actor; the plate has to actually land
            #expect(await ControllerWait.until {
                controller.chromaBackgroundImageName == "plate.png"
            }, "the chosen plate never reached the display stage")
        }
    }

    /// Cancelling the plate picker leaves the plate that was already set. The
    /// path is a persisted setting, and clearing it on a cancel would drop the
    /// art department's background between two clicks.
    @Test func cancellingThePlatePickerKeepsTheCurrentPlate() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.chromaKeyBackgroundImagePath = "/somewhere/plate.tif"

            try await FakeFilePanel.installed { panel in
                controller.chooseChromaBackgroundImage()

                #expect(panel.openRequests.count == 1)
                #expect(controller.settings.chromaKeyBackgroundImagePath
                            == "/somewhere/plate.tif")
            }
        }
    }

    /// The offload sheet's folder picker is a FOLDER picker with the caller's own
    /// wording on it — the source and the destination browsers look different to
    /// the operator and say which is which.
    @Test func theOffloadFolderPickerIsAFolderBrowserWithItsOwnWording() async throws {
        let disk = try MediaFixtures.makeDirectory("picker-offload")
        defer { try? FileManager.default.removeItem(at: disk) }

        try await FakeFilePanel.installed(opening: [[disk]]) { panel in
            let picked = OffloadPanels.pickFolder(message: "pick the card",
                                                  prompt: "Copy from")
            #expect(picked == disk)
            let request = try #require(panel.openRequests.first)
            #expect(request.directories)
            #expect(!request.files, "the card browser offered loose files")
            #expect(request.createDirectories)
            #expect(request.message == "pick the card")
            #expect(request.prompt == "Copy from")
        }
    }

    /// Cancelling it answers nothing rather than an arbitrary folder.
    @Test func cancellingTheOffloadFolderPickerAnswersNothing() async throws {
        try await FakeFilePanel.installed { _ in
            #expect(OffloadPanels.pickFolder(message: "m", prompt: "p") == nil)
        }
    }
}

/// The mapping from a `FilePanel` request to the AppKit panel it builds.
///
/// The suite answers the dialogs everywhere else, which means nothing otherwise
/// checks that a request's switches reach the real `NSOpenPanel` — and those
/// switches ARE the dialog: one that offers files where the caller asked for
/// folders puts a movie file in the record-folder setting. Building a panel shows
/// nothing and costs nothing; it is `runModal()` that stops the thread, and that
/// stays behind the seam.
@Suite @MainActor struct FilePanelConfigurationTests {
    @Test func aSaveRequestReachesThePanelsNameAndFolder() {
        let folder = URL(fileURLWithPath: "/Volumes/CARD_A001", isDirectory: true)
        let panel = FilePanel.configured(FilePanel.SaveRequest(
            suggestedName: "Nightshoot_selects.edl", directory: folder))
        #expect(panel.nameFieldStringValue == "Nightshoot_selects.edl")
        #expect(panel.directoryURL == folder)
    }

    /// A folder browser offers folders and NOT files, and lets the operator make
    /// one — a day's folder often does not exist yet.
    @Test func aFolderRequestBuildsAFolderBrowser() {
        let panel = FilePanel.configured(FilePanel.OpenRequest(
            files: false, directories: true, createDirectories: true,
            message: "pick the card", prompt: "Copy from"))
        #expect(!panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.canCreateDirectories)
        #expect(!panel.allowsMultipleSelection)
        #expect(panel.message == "pick the card")
        #expect(panel.prompt == "Copy from")
    }

    /// A file request with types on it filters to them and can take several at
    /// once — the look importer's shape.
    @Test func aTypedFileRequestFiltersAndTakesSeveral() throws {
        let cube = try #require(UTType(filenameExtension: "cube"))
        let panel = FilePanel.configured(FilePanel.OpenRequest(
            multiple: true, contentTypes: [cube]))
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
        #expect(panel.allowedContentTypes == [cube])
    }

    /// A request that names no types accepts everything. An empty list assigned
    /// to `allowedContentTypes` would filter every file out instead, which reads
    /// as an empty disk.
    @Test func anUntypedRequestAcceptsEverything() {
        let panel = FilePanel.configured(FilePanel.OpenRequest())
        #expect(panel.allowedContentTypes.isEmpty)
        #expect(panel.canChooseFiles)
    }
}
