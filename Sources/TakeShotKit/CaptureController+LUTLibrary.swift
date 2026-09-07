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

    /// The library holds something. Not the same question as `canApplyLUT`,
    /// which asks whether one is SELECTED.
    var hasLUTs: Bool { !availableLUTs.isEmpty }

    /// The library is the app's own folder rather than one the operator pointed
    /// it at — which decides three things the app may do to a folder and three
    /// it may not do to somebody else's.
    ///
    /// Creating it when it is missing is the sharp one. A chosen library lives
    /// on the show drive, and a drive that is not mounted yet leaves its mount
    /// point free: creating `/Volumes/SHOW/LUTs` there makes a folder on the
    /// BOOT disk, and the real drive then mounts as "SHOW 1" with every path in
    /// the app pointing at the phantom. So a chosen folder is only ever read.
    /// Emptying it is the other one — "Clear" belongs to the folder the app
    /// filled, not to the crew's master looks.
    var ownsLUTsDirectory: Bool { settings.lut.folderPath == nil }

    /// What "Clear looks" is enabled by: the app's own library, with something
    /// in it. One name for the pair, because a condition written at a surface
    /// is a condition the next surface writes slightly differently — and the
    /// deletion itself asks the same question again (`clearLUTs`).
    var canClearLUTs: Bool { hasLUTs && ownsLUTsDirectory }

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
        if ownsLUTsDirectory {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
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
        if ownsLUTsDirectory {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        } else if !FileManager.default.fileExists(atPath: dir.path) {
            // a chosen library that is not there is a drive that is not
            // mounted, and the answer is to say so — not to make the folder
            lastError = L("toast_lut_folder_missing", dir.path)
            return
        }
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
    /// Open the look library in Finder. Created first only when it is the
    /// app's own — see `ownsLUTsDirectory`.
    func openLUTsInFinder() {
        if ownsLUTsDirectory {
            FinderOpen.ownFolder(lutsDirectory)
        } else {
            FinderOpen.folder(lutsDirectory)
        }
    }
    /// Where a stored `lut.folderPath` points. Empty counts as unset, which is
    /// what a hand-edited blob (or a cleared text field, if this ever becomes
    /// one) would otherwise turn into a library at "/".
    nonisolated static func lutsDirectory(forStoredPath path: String?) -> URL {
        guard let path, !path.isEmpty else { return defaultLUTsDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    /// Take up the library the operator chose, at launch.
    ///
    /// Only when they chose one. The suites inject `lutsDirectory` so their
    /// fixtures never land in the operator's real Application Support folder
    /// (and `clearLUTs` never deletes the looks they went on set with), and an
    /// unset path assigned unconditionally would undo that injection for every
    /// one of them.
    func adoptStoredLUTFolder(_ stored: CaptureSettings) {
        guard stored.lut.folderPath != nil else { return }
        lutsDirectory = Self.lutsDirectory(forStoredPath: stored.lut.folderPath)
    }
    /// Ask the operator for a look library.
    ///
    /// A folder picker rather than a text field: the answer is a path that has
    /// to exist, and the panel is the one control that cannot produce one that
    /// does not (owner: "path папки лутов хочу чтобы можно было выбирать").
    func chooseLUTsFolder() {
        guard let url = FilePanel.openOne(.init(
            files: false, directories: true, createDirectories: true,
            directory: lutsDirectory)) else { return }
        setLUTsFolder(url)
    }
    /// Point the library at `url` — nil puts it back at the app's own folder.
    ///
    /// Everything downstream of the folder is re-derived here rather than left
    /// to the next read. Two things would otherwise survive the move: the
    /// cached cube, which is keyed by FILE NAME alone, so a second library with
    /// its own `Rec709.cube` would keep showing the first one's grade; and a
    /// selection the new folder does not contain, which would reach the
    /// operator as a load error they did not ask for instead of simply no look.
    func setLUTsFolder(_ url: URL?) {
        settings.lut.folderPath = url?.path
        lutsDirectory = Self.lutsDirectory(forStoredPath: settings.lut.folderPath)
        cubeCache = nil
        reloadLUTList()
        if let fileName = settings.lut.fileName,
           !availableLUTs.contains(where: { $0.fileName == fileName }) {
            selectLUT(fileName: nil)
        } else {
            rebuildLUT()
        }
    }
    /// Delete every imported look and clear the selected one.
    ///
    /// Only ever the app's OWN library. Pointed at the show's LUT folder, this
    /// button would delete the crew's master looks — and the operator who
    /// pressed it would be reading a confirmation about "imported LUTs", which
    /// is not what that folder holds. Refused here as well as disabled in
    /// Settings: the guard belongs with the deletion, not with the button.
    func clearLUTs() {
        guard ownsLUTsDirectory else { return }
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
