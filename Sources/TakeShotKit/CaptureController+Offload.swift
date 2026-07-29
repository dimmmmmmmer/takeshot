import AVFoundation
import AppKit
import CaptureCore
import CryptoKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Verified offload of a camera card: recursive copy with SHA-256 on both
/// sides and a manifest.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    nonisolated static let backupQueue = DispatchQueue(
        label: "takeshot.offload", qos: .utility)

    func offloadFolder() {
        guard let (source, destDir) = pickOffloadFolders() else { return }
        offloadStatus = L("offload_scanning")
        Self.backupQueue.async { [weak self] in
            let scan = Self.scanOffloadSource(source)
            let files = scan.files
            var failures = scan.failures
            var manifest = "File,SHA256,Bytes,Verified At\n"
            for (index, file) in files.enumerated() {
                DispatchQueue.main.async { [weak self] in
                    self?.offloadStatus = L("offload_progress", index + 1,
                                            files.count)
                }
                if let row = Self.copyVerified(file, from: source, to: destDir,
                                               failures: &failures) {
                    manifest += row
                }
            }
            Self.writeManifest(manifest, to: destDir, failures: &failures)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.offloadStatus = nil
                if failures.isEmpty {
                    self.lastNotice = L("offload_done", files.count)
                } else {
                    self.lastError = L("offload_failed", failures.count,
                                       failures.first ?? "")
                }
            }
        }
    }

    /// Source and destination pickers; nil when the operator cancels either.
    /// The card's own folder name is kept inside the chosen destination.
    private func pickOffloadFolders() -> (source: URL, destination: URL)? {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseFiles = false
        sourcePanel.canChooseDirectories = true
        sourcePanel.message = L("offload_pick_source")
        sourcePanel.prompt = L("offload_source_prompt")
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url
        else { return nil }
        let destPanel = NSOpenPanel()
        destPanel.canChooseFiles = false
        destPanel.canChooseDirectories = true
        destPanel.canCreateDirectories = true
        destPanel.message = L("offload_pick_dest")
        destPanel.prompt = L("offload_dest_prompt")
        if let saved = settings.backupPath {
            destPanel.directoryURL = URL(fileURLWithPath: saved)
        }
        guard destPanel.runModal() == .OK, let destRoot = destPanel.url
        else { return nil }
        settings.backupPath = destRoot.path
        return (source, destRoot.appendingPathComponent(source.lastPathComponent))
    }

    /// Every file on the card. A card copy must be COMPLETE: hidden files
    /// included, and an unreadable directory is a failure, not a silent skip.
    nonisolated private static func scanOffloadSource(
        _ source: URL) -> (files: [URL], failures: [String]) {
        var files: [URL] = []
        var failures: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isDirectoryKey],
            options: [], errorHandler: { url, error in
                failures.append("\(url.lastPathComponent) "
                    + "(\(error.localizedDescription))")
                return true
            }) {
            for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory != true {
                files.append(url)
            }
        }
        return (files, failures)
    }

    /// Copy one file and verify both sides by SHA-256. Returns its manifest
    /// row, or nil after appending the reason to `failures`.
    nonisolated private static func copyVerified(
        _ file: URL, from source: URL, to destDir: URL,
        failures: inout [String]) -> String? {
        let relative = file.path.replacingOccurrences(
            of: source.path + "/", with: "")
        do {
            var dest = destDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // never clobber an existing copy — uniquify instead
            dest = CapturePipeline.uniqueURL(for: dest)
            try FileManager.default.copyItem(at: file, to: dest)
            let sourceHash = try sha256(of: file)
            let destHash = try sha256(of: dest, bypassCache: true)
            guard sourceHash == destHash else {
                failures.append(relative + " (checksum mismatch)")
                return nil
            }
            let size = (try? FileManager.default
                .attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            return [TakeLogExporter.escapedField(relative),
                    sourceHash, String(size),
                    ISO8601DateFormatter().string(from: Date())]
                .joined(separator: ",") + "\n"
        } catch {
            failures.append(file.lastPathComponent
                + " (\(error.localizedDescription))")
            return nil
        }
    }

    nonisolated private static func writeManifest(_ manifest: String, to destDir: URL,
                                                  failures: inout [String]) {
        do {
            try manifest.write(
                to: destDir.appendingPathComponent("offload-manifest.csv"),
                atomically: true, encoding: .utf8)
        } catch {
            // a vanished backup volume must not report "offload done"
            failures.append("offload-manifest.csv "
                + "(\(error.localizedDescription))")
        }
    }

    /// `bypassCache: true` reads through F_NOCACHE — verifying a fresh copy
    /// through the unified page cache would verify RAM, not the disk.
    nonisolated private static func sha256(of url: URL,
                                           bypassCache: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassCache {
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
