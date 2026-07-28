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
    func offloadFolder() {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseFiles = false
        sourcePanel.canChooseDirectories = true
        sourcePanel.message = L("offload_pick_source")
        sourcePanel.prompt = L("offload_source_prompt")
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url
        else { return }
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
        else { return }
        settings.backupPath = destRoot.path
        let destDir = destRoot.appendingPathComponent(source.lastPathComponent)
        offloadStatus = L("offload_scanning")
        Self.backupQueue.async { [weak self] in
            var files: [URL] = []
            var failures: [String] = []
            // a card copy must be COMPLETE: hidden files included, and an
            // unreadable directory is a failure, not a silent skip
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
            var manifest = "File,SHA256,Bytes,Verified At\n"
            for (index, file) in files.enumerated() {
                DispatchQueue.main.async { [weak self] in
                    self?.offloadStatus = L("offload_progress", index + 1,
                                            files.count)
                }
                do {
                    let relative = file.path.replacingOccurrences(
                        of: source.path + "/", with: "")
                    var dest = destDir.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    // never clobber an existing copy — uniquify instead
                    dest = CapturePipeline.uniqueURL(for: dest)
                    try FileManager.default.copyItem(at: file, to: dest)
                    let sourceHash = try Self.sha256(of: file)
                    let destHash = try Self.sha256(of: dest, bypassCache: true)
                    guard sourceHash == destHash else {
                        failures.append(relative + " (checksum mismatch)")
                        continue
                    }
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                    manifest += [TakeLogExporter.escapedField(relative),
                                 sourceHash, String(size),
                                 ISO8601DateFormatter().string(from: Date())]
                        .joined(separator: ",") + "\n"
                } catch {
                    failures.append(file.lastPathComponent
                        + " (\(error.localizedDescription))")
                }
            }
            do {
                try manifest.write(
                    to: destDir.appendingPathComponent("offload-manifest.csv"),
                    atomically: true, encoding: .utf8)
            } catch {
                // a vanished backup volume must not report "offload done"
                failures.append("offload-manifest.csv "
                    + "(\(error.localizedDescription))")
            }
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
