import Foundation
import Testing

@testable import CaptureCore

/// XXH64 is only useful if it agrees with every other implementation on earth:
/// the whole point of writing xxh64 into an MHL manifest is that Silverstack or
/// OffShoot re-computes the same 16 hex digits weeks later. So this suite pins
/// the published reference vectors, then cross-checks the streaming hasher
/// against a second, independently structured implementation of the published
/// algorithm over every length that exercises a different code path.
struct XXH64Tests {
    /// Published xxHash64 vectors (seed 0). These are the anchor — they are the
    /// numbers `xxhsum -H64` prints, and each one lands in a different tail
    /// path: empty input skips the accumulators entirely, one byte exercises
    /// the byte loop, three the byte loop twice, and the sentence exercises the
    /// 8-byte and 4-byte tail steps after four full stripes.
    @Test func matchesThePublishedReferenceVectors() {
        #expect(XXH64.hash(Data()) == 0xEF46_DB37_51D8_E999)
        #expect(XXH64.hash(Data("a".utf8)) == 0xD24E_C4F1_A98C_6E5B)
        #expect(XXH64.hash(Data("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
        #expect(XXH64.hash(Data("Nobody inspects the spammish repetition".utf8))
            == 0xFBCE_A83C_8A37_8BF1)
    }

    @Test func hexIsSixteenZeroPaddedDigits() {
        #expect(XXH64.hex(XXH64.hash(Data())) == "ef46db3751d8e999")
        #expect(XXH64.hex(0) == "0000000000000000")
        #expect(XXH64.hex(0xFF) == "00000000000000ff")
    }

    /// The 0…99 byte sequence, hashed with and without a seed. Verified against
    /// `Reference.hash` below (a from-the-spec one-shot pass) at every prefix
    /// length, which is what makes the two literals here trustworthy as
    /// regression pins rather than just "whatever the code did".
    @Test func hashesTheZeroToNinetyNineSequence() {
        let bytes = Data((0..<100).map { UInt8($0) })

        #expect(XXH64.hash(bytes) == Reference.hash(bytes, seed: 0))
        #expect(XXH64.hash(bytes, seed: Self.seed)
            == Reference.hash(bytes, seed: Self.seed))
        #expect(XXH64.hex(XXH64.hash(bytes)) == "6ac1e58032166597")
        // leading zero byte: the digest is 16 digits or it will not match
        // another tool's manifest
        #expect(XXH64.hex(XXH64.hash(bytes, seed: Self.seed))
            == "00278bda0ee3f586")
    }

    /// Prime-derived, like the reference test suite's non-zero seed: a seed of
    /// 1 leaves most of the seeding arithmetic looking like the unseeded case.
    private static let seed: UInt64 = 0x9E37_79B1_85EB_CA87

    /// Every length from nothing to well past four stripes, seeded and not.
    /// Off-by-one in the stripe loop, the 8/4/1-byte tail steps and the
    /// "did the accumulators ever run" branch all live in this range.
    @Test func agreesWithTheReferenceAtEveryLength() {
        for length in 0...200 {
            let bytes = Data((0..<length).map { UInt8(($0 * 7 + 13) & 0xFF) })
            for seed in [UInt64(0), 1, Self.seed] {
                #expect(XXH64.hash(bytes, seed: seed)
                    == Reference.hash(bytes, seed: seed),
                        "length \(length), seed \(seed)")
            }
        }
    }

    /// A card offload feeds the hasher whatever came off the disk, so the digest
    /// must not depend on where the chunk boundaries fell. Chunk sizes are
    /// chosen around the 32-byte stripe: below it, on it, either side of it, and
    /// well above.
    @Test func chunkBoundariesDoNotChangeTheDigest() {
        let bytes = Data((0..<277).map { UInt8(($0 * 31 + 5) & 0xFF) })
        let expected = XXH64.hash(bytes, seed: Self.seed)

        for chunk in [1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 64, 100, 277, 512] {
            var hasher = XXH64(seed: Self.seed)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunk, bytes.count)
                hasher.update(bytes[offset..<end])
                offset = end
            }
            #expect(hasher.finalize() == expected, "chunk size \(chunk)")
        }
    }

    /// Feeding nothing at all, and feeding empty chunks around real ones, must
    /// both land on the empty-input vector / the same digest.
    @Test func emptyUpdatesAreIgnored() {
        var hasher = XXH64()
        hasher.update(Data())
        #expect(hasher.finalize() == 0xEF46_DB37_51D8_E999)

        var padded = XXH64()
        padded.update(Data())
        padded.update(Data("abc".utf8))
        padded.update(Data())
        #expect(padded.finalize() == XXH64.hash(Data("abc".utf8)))
    }

    /// `finalize()` folds the tail into a copy, so asking twice — which the
    /// engine does when it reports a hash and then writes it into the manifest —
    /// has to give the same answer.
    @Test func finalizeIsRepeatable() {
        var hasher = XXH64()
        hasher.update(Data("Nobody inspects the spammish repetition".utf8))
        let first = hasher.finalize()
        #expect(hasher.finalize() == first)
        hasher.update(Data("!".utf8))
        #expect(hasher.finalize() != first)
    }

    /// A second implementation of the published algorithm, deliberately written
    /// as a single one-shot pass over an array with no buffering state — the
    /// production hasher's stripe buffer is exactly where a streaming hash goes
    /// wrong, and a bug there cannot hide in code that has no buffer.
    private enum Reference {
        static let p1: UInt64 = 11_400_714_785_074_694_791
        static let p2: UInt64 = 14_029_467_366_897_019_727
        static let p3: UInt64 = 1_609_587_929_392_839_161
        static let p4: UInt64 = 9_650_029_242_287_828_579
        static let p5: UInt64 = 2_870_177_450_012_600_261

        static func hash(_ data: Data, seed: UInt64) -> UInt64 {
            let bytes = [UInt8](data)
            var hash: UInt64
            var index = 0
            if bytes.count >= 32 {
                var v1 = seed &+ p1 &+ p2
                var v2 = seed &+ p2
                var v3 = seed
                var v4 = seed &- p1
                while index + 32 <= bytes.count {
                    v1 = round(v1, word(bytes, index))
                    v2 = round(v2, word(bytes, index + 8))
                    v3 = round(v3, word(bytes, index + 16))
                    v4 = round(v4, word(bytes, index + 24))
                    index += 32
                }
                hash = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
                for accumulator in [v1, v2, v3, v4] {
                    hash = (hash ^ round(0, accumulator)) &* p1 &+ p4
                }
            } else {
                hash = seed &+ p5
            }
            hash &+= UInt64(bytes.count)
            return avalanche(tail(hash, bytes, from: index))
        }

        private static func tail(_ input: UInt64, _ bytes: [UInt8],
                                 from start: Int) -> UInt64 {
            var hash = input
            var index = start
            while index + 8 <= bytes.count {
                hash ^= round(0, word(bytes, index))
                hash = rotl(hash, 27) &* p1 &+ p4
                index += 8
            }
            if index + 4 <= bytes.count {
                hash ^= UInt64(halfWord(bytes, index)) &* p1
                hash = rotl(hash, 23) &* p2 &+ p3
                index += 4
            }
            while index < bytes.count {
                hash ^= UInt64(bytes[index]) &* p5
                hash = rotl(hash, 11) &* p1
                index += 1
            }
            return hash
        }

        /// Little-endian assembled a byte at a time — no loads, no alignment,
        /// nothing shared with the production reader.
        private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for byte in 0..<8 {
                value |= UInt64(bytes[offset + byte]) << (8 * UInt64(byte))
            }
            return value
        }

        private static func halfWord(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for byte in 0..<4 {
                value |= UInt32(bytes[offset + byte]) << (8 * UInt32(byte))
            }
            return value
        }

        private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
            rotl(accumulator &+ input &* p2, 31) &* p1
        }

        private static func avalanche(_ input: UInt64) -> UInt64 {
            var hash = input
            hash ^= hash >> 33
            hash &*= p2
            hash ^= hash >> 29
            hash &*= p3
            hash ^= hash >> 32
            return hash
        }

        private static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 {
            (value << count) | (value >> (64 - count))
        }
    }
}
