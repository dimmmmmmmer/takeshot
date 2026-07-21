import CoreImage
import Foundation

/// 3D LUT из файла .cube (Adobe/Resolve-формат).
public struct CubeLUT: Sendable {
    public let size: Int
    /// RGBA float32, порядок как требует CIColorCube.
    public let data: Data
    public let name: String

    public enum ParseError: Error, LocalizedError {
        case missingSize
        case wrongEntryCount(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .missingSize:
                return "LUT_3D_SIZE not found — is this a 3D .cube file?"
            case .wrongEntryCount(let expected, let got):
                return "Cube data mismatch: expected \(expected) entries, got \(got)"
            }
        }
    }

    public static func load(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ text: String, name: String = "LUT") throws -> CubeLUT {
        var size = 0
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
                continue
            }
            // TITLE, DOMAIN_MIN/MAX, LUT_1D_* — пропускаем
            if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN")
                || upper.hasPrefix("LUT_") { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 {
                values.append(contentsOf: parts)
            }
        }
        guard size > 1 else { throw ParseError.missingSize }
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

    /// CIFilter для применения LUT (каждому потребителю — свой экземпляр).
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
