import CaptureCore
import Foundation
import UniformTypeIdentifiers

/// The look files themselves: importing them, listing them, and mirroring them
/// into Resolve so the same look is at hand in the grade.
///
/// Split out of `+LUT`: getting a look onto the machine and applying it to a
/// picture are separate jobs, and everything here is file management with a
/// modal in the middle of it — `DuplicateLookPrompt`, which is a seam for the
/// same reason `FilePanel` is: the three arms below are file operations on the
/// operator's library and one of them deletes.
extension CaptureController {
    struct LUTInfo: Identifiable, Equatable {
        var id: String { fileName }
        var fileName: String
        var name: String
    }

    enum DuplicateLUTChoice { case replace, keepBoth, skip }

    /// The library holds something: what "Clear looks" is enabled by. Not the
    /// same question as `canApplyLUT`, which asks whether one is SELECTED.
    var hasLUTs: Bool { !availableLUTs.isEmpty }

    /// Where looks live when nobody says otherwise. The controller reads the
    /// instance property seeded from this, not the static — see `lutsDirectory`.
    nonisolated static var defaultLUTsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("TakeShot/LUTs", isDirectory: true)
    }

    /// DaVinci Resolve's LUT directory — imported LUTs are mirrored into a
    /// TakeShot subfolder there, so the same look is at hand in Resolve.
    nonisolated static var defaultResolveLUTDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent(
                "Application Support/Blackmagic Design/DaVinci Resolve/LUT/TakeShot",
                isDirectory: true)
    }

    /// What counts as a look in the library. A .cube is a lattice; the three
    /// ASC CDL spellings are nine numbers that become one on load (see
    /// `readLook`). One list rather than a condition per call site — the import
    /// panel, the folder scan and the wipe all have to agree about it, and they
    /// used to agree by each spelling "cube" out separately.
    nonisolated static let lookExtensions = ["cube"] + CDLLook.fileExtensions

    func reloadLUTList() {
        let dir = lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        availableLUTs = files
            .filter { Self.lookExtensions.contains($0.pathExtension.lowercased()) }
            .map { LUTInfo(fileName: $0.lastPathComponent,
                           name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name < $1.name }
    }
    /// Import a look: copied into the app folder and selected right away.
    func importLUT() {
        // .cdl and .ccc have no registered type, so these are dynamic UTIs that
        // filter on the extension — which is what is wanted. .cc does have one
        // (C++ source), so the panel also offers .cpp files; picking one fails
        // to parse with a visible error rather than doing anything quietly.
        let chosen = FilePanel.open(.init(
            multiple: true,
            contentTypes: Self.lookExtensions
                .compactMap { UTType(filenameExtension: $0) }))
        guard !chosen.isEmpty else { return }
        adoptLooks(from: chosen)
    }
    /// Copy chosen look files into the library and select the last one.
    ///
    /// Split from `importLUT` so the flow that matters — a file arriving,
    /// appearing in the list and being applied — can be driven without a modal
    /// panel standing in front of it. The duplicate prompt is still a modal, so
    /// a caller with names it knows are new never reaches one.
    func adoptLooks(from urls: [URL]) {
        let dir = lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lastName: String?
        for url in urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                // duplicate name: let the user decide instead of silently replacing
                switch DuplicateLookPrompt.ask(name: url.lastPathComponent) {
                case .replace:
                    try? FileManager.default.removeItem(at: dest)
                case .keepBoth:
                    dest = CapturePipeline.uniqueURL(for: dest)
                case .skip:
                    continue
                }
            }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                lastName = dest.lastPathComponent
                mirrorLUTToResolve(dest)
            } catch {
                lastError = L("toast_lut_import_failed", error.localizedDescription)
            }
        }
        reloadLUTList()
        if let lastName {
            selectLUT(fileName: lastName)
        }
    }
    /// Read the selected look off disk, into the cube every render path takes.
    ///
    /// A .cube is a lattice already; an ASC CDL is nine numbers, and it is
    /// rasterized HERE rather than given a render path of its own. Preview,
    /// bake and compare all consume a `CubeLUT`, so a CDL that took its own
    /// route through them would be a second chance for the live picture and the
    /// recorded file to disagree — the one thing this app exists to prevent.
    func loadLook(named fileName: String) {
        do {
            let (cube, cdl) = try Self.readLook(
                at: lutsDirectory.appendingPathComponent(fileName))
            currentCube = cube
            currentCDL = cdl
            cubeCache = LoadedLook(fileName: fileName, cube: cube, cdl: cdl)
        } catch {
            lastError = L("toast_lut_failed", error.localizedDescription)
            settings.lut.fileName = nil
        }
    }
    /// A look file as the pair the app works in: the lattice, and the CDL
    /// parameters when the file was one (nil for a .cube — a lattice cannot be
    /// reduced to slope/offset/power, and claiming otherwise would put invented
    /// numbers in the EDL).
    nonisolated static func readLook(at url: URL) throws -> (CubeLUT, CDLLook?) {
        guard CDLLook.fileExtensions.contains(url.pathExtension.lowercased())
        else { return (try CubeLUT.load(url: url), nil) }
        let cdl = try CDLLook.load(url: url)
        return (cdl.cube(), cdl)
    }
    /// Open the imported-LUTs folder in Finder.
    func openLUTsInFinder() {
        FinderOpen.ownFolder(lutsDirectory)
    }
    /// Delete every imported look and clear the selected one.
    func clearLUTs() {
        let dir = lutsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files
        where Self.lookExtensions.contains(file.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
        }
        selectLUT(fileName: nil)
        reloadLUTList()
    }
    /// Mirror an imported LUT into DaVinci Resolve's LUT/TakeShot folder.
    ///
    /// .cube only. Resolve's LUT folder is scanned for lattices; an ASC CDL
    /// dropped in it is not a LUT and does not appear in the LUT menu, so
    /// mirroring one would put a file the colourist cannot use where they would
    /// go looking for the look. A CDL reaches them through the EDL instead
    /// (`*ASC_SOP`/`*ASC_SAT`), which is the route their tools expect.
    private func mirrorLUTToResolve(_ url: URL) {
        guard url.pathExtension.lowercased() == "cube" else { return }
        let dir = resolveLUTDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
