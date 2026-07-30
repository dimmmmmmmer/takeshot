import AppKit
import CaptureCore
import Foundation

/// The .cube files themselves: importing them, listing them, and mirroring them
/// into Resolve so the same look is at hand in the grade.
///
/// Split out of `+LUT`: getting a look onto the machine and applying it to a
/// picture are separate jobs, and everything here is file management with a
/// modal in the middle of it.
extension CaptureController {
    struct LUTInfo: Identifiable, Equatable {
        var id: String { fileName }
        var fileName: String
        var name: String
    }

    enum DuplicateLUTChoice { case replace, keepBoth, skip }

    nonisolated static var lutsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("TakeShot/LUTs", isDirectory: true)
    }

    /// DaVinci Resolve's LUT directory — imported LUTs are mirrored into a
    /// TakeShot subfolder there, so the same look is at hand in Resolve.
    nonisolated static var resolveLUTDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent(
                "Application Support/Blackmagic Design/DaVinci Resolve/LUT/TakeShot",
                isDirectory: true)
    }

    func reloadLUTList() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        availableLUTs = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { LUTInfo(fileName: $0.lastPathComponent,
                           name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name < $1.name }
    }
    /// Import .cube: copied into the app folder and selected right away.
    func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lastName: String?
        for url in panel.urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                // duplicate name: let the user decide instead of silently replacing
                switch Self.askDuplicateLUT(name: url.lastPathComponent) {
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
                lastError = "LUT import failed: \(error.localizedDescription)"
            }
        }
        reloadLUTList()
        if let lastName {
            selectLUT(fileName: lastName)
        }
    }
    /// Open the imported-LUTs folder in Finder.
    func openLUTsInFinder() {
        let dir = Self.lutsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
    /// Delete all imported .cube files and clear the selected LUT.
    func clearLUTs() {
        let dir = Self.lutsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "cube" {
            try? FileManager.default.removeItem(at: file)
        }
        selectLUT(fileName: nil)
        reloadLUTList()
    }
    /// Modal: what to do with an already-imported LUT of the same name.
    private static func askDuplicateLUT(name: String) -> DuplicateLUTChoice {
        let alert = NSAlert()
        alert.messageText = L("lut_duplicate_title", name)
        alert.informativeText = L("lut_duplicate_text")
        alert.addButton(withTitle: L("lut_replace"))
        alert.addButton(withTitle: L("lut_keep_both"))
        alert.addButton(withTitle: L("lut_skip"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        default: return .skip
        }
    }
    /// Mirror an imported LUT into DaVinci Resolve's LUT/TakeShot folder.
    private func mirrorLUTToResolve(_ url: URL) {
        let dir = Self.resolveLUTDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}
