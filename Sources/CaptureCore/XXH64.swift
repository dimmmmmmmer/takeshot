import Foundation

/// xxHash64 (XXH64) — the checksum the DIT world runs on.
///
/// ASC MHL, Pomfort Silverstack, OffShoot and Hedge all default to xxHash64, so
/// a manifest TakeShot writes has to carry the numbers those tools compute, bit
/// for bit. It is also roughly an order of magnitude faster than SHA-256, which
/// on a card offload is the difference between "the checksum is free" and "the
/// checksum sets the pace".
///
/// Written out here rather than pulled in: the app ships no external
/// dependencies (see CONTRIBUTING), and the algorithm is small, frozen and
/// covered by the reference vectors in `XXH64Tests`.
///
/// Streaming by construction — a card holds files far larger than memory, so
/// `update` must accept arbitrary chunk sizes and produce the same digest as a
/// one-shot hash of the concatenation. Everything is `&+`/`&*`: XXH64 is
/// defined on wrapping 64-bit arithmetic, and a trapping operator would crash
/// on the first real file.
public struct XXH64: Sendable {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    /// One 32-byte stripe feeds four accumulators.
    private static let stripeBytes = 32

    private let seed: UInt64
    private var acc1: UInt64
    private var acc2: UInt64
    private var acc3: UInt64
    private var acc4: UInt64
    /// Bytes held back because they did not fill a stripe. At most 31.
    private var pending: [UInt8] = []
    /// Length of everything fed in so far — it goes into the digest itself.
    private var total: UInt64 = 0

    public init(seed: UInt64 = 0) {
        self.seed = seed
        acc1 = seed &+ Self.prime1 &+ Self.prime2
        acc2 = seed &+ Self.prime2
        acc3 = seed
        acc4 = seed &- Self.prime1
    }

    // MARK: - streaming

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        total &+= UInt64(bytes.count)
        var offset = 0
        // Top up a partial stripe from the previous chunk first. The copy is
        // taken out of `pending` before the accumulators are touched: mutating
        // self while a stored array is borrowed is an exclusivity violation.
        if !pending.isEmpty {
            let wanted = min(Self.stripeBytes - pending.count, bytes.count)
            pending.append(contentsOf: bytes[offset..<(offset + wanted)])
            offset += wanted
            if pending.count == Self.stripeBytes {
                let stripe = pending
                pending.removeAll(keepingCapacity: true)
                stripe.withUnsafeBytes { consumeStripe($0, at: 0) }
            }
        }
        while offset + Self.stripeBytes <= bytes.count {
            consumeStripe(bytes, at: offset)
            offset += Self.stripeBytes
        }
        if offset < bytes.count {
            pending.append(contentsOf: bytes[offset..<bytes.count])
        }
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    /// The digest of everything fed in. Non-mutating: the tail is folded into a
    /// copy, so a hasher can be finalized without being consumed.
    public func finalize() -> UInt64 {
        var hash: UInt64
        if total >= UInt64(Self.stripeBytes) {
            hash = Self.rotl(acc1, 1) &+ Self.rotl(acc2, 7)
                &+ Self.rotl(acc3, 12) &+ Self.rotl(acc4, 18)
            hash = Self.mergeAccumulator(hash, acc1)
            hash = Self.mergeAccumulator(hash, acc2)
            hash = Self.mergeAccumulator(hash, acc3)
            hash = Self.mergeAccumulator(hash, acc4)
        } else {
            // Under one stripe the accumulators never ran; every byte is still
            // in `pending` and the digest starts from the seed.
            hash = seed &+ Self.prime5
        }
        hash &+= total
        hash = pending.withUnsafeBytes { Self.foldTail(hash, $0) }
        return Self.avalanche(hash)
    }

    // MARK: - convenience

    public static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        var hasher = XXH64(seed: seed)
        hasher.update(data)
        return hasher.finalize()
    }

    /// Sixteen lowercase hex digits — how xxh64 appears in an MHL manifest and
    /// in `xxhsum` output. Zero-padded: a digest with leading zero bytes that
    /// printed short would not compare equal to another tool's.
    public static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    // MARK: - the algorithm

    private mutating func consumeStripe(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        acc1 = Self.round(acc1, Self.load64(bytes, offset))
        acc2 = Self.round(acc2, Self.load64(bytes, offset + 8))
        acc3 = Self.round(acc3, Self.load64(bytes, offset + 16))
        acc4 = Self.round(acc4, Self.load64(bytes, offset + 24))
    }

    /// The 0…31 trailing bytes: 8 at a time, then 4, then one at a time.
    private static func foldTail(_ input: UInt64,
                                 _ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash = input
        var offset = 0
        while offset + 8 <= bytes.count {
            hash ^= round(0, load64(bytes, offset))
            hash = rotl(hash, 27) &* prime1 &+ prime4
            offset += 8
        }
        if offset + 4 <= bytes.count {
            hash ^= UInt64(load32(bytes, offset)) &* prime1
            hash = rotl(hash, 23) &* prime2 &+ prime3
            offset += 4
        }
        while offset < bytes.count {
            hash ^= UInt64(bytes[offset]) &* prime5
            hash = rotl(hash, 11) &* prime1
            offset += 1
        }
        return hash
    }

    private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        var value = accumulator &+ input &* prime2
        value = rotl(value, 31)
        return value &* prime1
    }

    private static func mergeAccumulator(_ hash: UInt64,
                                         _ accumulator: UInt64) -> UInt64 {
        (hash ^ round(0, accumulator)) &* prime1 &+ prime4
    }

    /// Final bit mixing — without it the low bits of short inputs collide.
    private static func avalanche(_ input: UInt64) -> UInt64 {
        var hash = input
        hash ^= hash >> 33
        hash &*= prime2
        hash ^= hash >> 29
        hash &*= prime3
        hash ^= hash >> 32
        return hash
    }

    private static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    /// XXH64 reads its input little-endian regardless of the host, and the
    /// offsets are wherever the chunk landed — hence the unaligned load.
    private static func load64(_ bytes: UnsafeRawBufferPointer,
                               _ offset: Int) -> UInt64 {
        UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset,
                                                 as: UInt64.self))
    }

    private static func load32(_ bytes: UnsafeRawBufferPointer,
                               _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset,
                                                 as: UInt32.self))
    }
}
