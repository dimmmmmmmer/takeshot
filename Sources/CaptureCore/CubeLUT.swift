@preconcurrency import CoreImage
import Foundation

/// A 3D LUT from a .cube file (Adobe/Resolve format).
public struct CubeLUT: Sendable {
    public let size: Int
    /// RGBA float32, in the order CIColorCube expects.
    public let data: Data
    public let name: String

    public enum ParseError: Error, LocalizedError {
        case missingSize
        case unreasonableSize(Int)
        case wrongEntryCount(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .missingSize:
                return "LUT_3D_SIZE not found — is this a 3D .cube file?"
            case .unreasonableSize(let size):
                return "LUT_3D_SIZE \(size) is outside the supported range "
                    + "(2…\(CubeLUT.maximumSize))"
            case .wrongEntryCount(let expected, let got):
                return "Cube data mismatch: expected \(expected) entries, got \(got)"
            }
        }
    }

    /// The largest lattice accepted. Real cubes are 17/33/65 (Resolve tops out
    /// at 65, a rare tool writes 129); 256 is beyond all of them. The cap is
    /// what makes the entry-count arithmetic below safe against a corrupted
    /// header — `size³ * 3` overflows Int from 2,097,152 up, and an overflow
    /// here is a trap that takes the app down mid-shoot over a bad file.
    public static let maximumSize = 256

    public static func load(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ text: String, name: String = "LUT") throws -> CubeLUT {
        // Windows tools re-save .cube files with a UTF-8 BOM; left in place it
        // glues itself to the first header line and the size is never found.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var size = 0
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first != "#" else { continue }
            // uppercase only header lines: a 65³ cube is ~275k DATA lines and
            // a per-line uppercased() measured as a 100-300 ms launch stall
            if first.isLetter {
                let upper = line.uppercased()
                if upper.hasPrefix("LUT_3D_SIZE") {
                    size = Int(line.split(separator: " ").last
                        .map(String.init) ?? "") ?? 0
                }
                // TITLE, DOMAIN_MIN/MAX, LUT_1D_* — skip
                continue
            }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 {
                values.append(contentsOf: parts)
            }
        }
        guard size > 1 else { throw ParseError.missingSize }
        // before any arithmetic on it — see maximumSize
        guard size <= Self.maximumSize else {
            throw ParseError.unreasonableSize(size)
        }
        let expected = size * size * size * 3
        guard values.count == expected else {
            throw ParseError.wrongEntryCount(expected: expected, got: values.count)
        }
        // RGB → RGBA
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i])
            rgba.append(values[i + 1])
            rgba.append(values[i + 2])
            rgba.append(1)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: data, name: name)
    }

    /// A CIFilter that applies the LUT (a fresh instance per consumer).
    public func makeFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        if let space = CGColorSpace(name: CGColorSpace.itur_709) {
            filter.setValue(space, forKey: "inputColorSpace")
        }
        return filter
    }
}
