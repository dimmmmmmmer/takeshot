import Foundation
import Testing

@testable import CaptureCore

/// **Which free-space number the preflight believes.**
///
/// The offload refused a card with "not enough space: needs 31.5 GB, 0 bytes
/// free" onto a 4 TB shuttle with 1.5 TB on it, while the destination tile
/// beside it read 1.5 TB free — off the same key (owner, 2026-09-08).
///
/// `volumeAvailableCapacityForImportantUsage` is written for the BOOT volume:
/// it counts space the system could purge, and a volume that cannot account for
/// that may answer 0 with terabytes free. So a zero from it is not an answer,
/// and the plain capacity — which an external drive can always give — is.
@Suite struct OffloadFreeSpaceTests {
    @Test func aZeroFromTheBootVolumesKeyIsNotAnAnswer() {
        #expect(OffloadTarget.available(important: 0, plain: 1_500_000_000_000)
                    == 1_500_000_000_000)
        #expect(OffloadTarget.available(important: nil, plain: 512) == 512)
    }

    /// When it does answer, it is the better number of the two: it includes
    /// space the system would free up rather than only what is unused today.
    @Test func theImportantUsageNumberWinsWhenItHasOne() {
        #expect(OffloadTarget.available(important: 2000, plain: 1000) == 2000)
    }

    /// **No number is nil, and nil does not fail the preflight.** A check that
    /// refuses on a reading it could not take costs the operator the offload;
    /// a disk that really is full fails on the first write, saying so.
    @Test func noNumberAtAllIsNotAFullDisk() {
        #expect(OffloadTarget.available(important: nil, plain: nil) == nil)
        #expect(OffloadTarget.available(important: 0, plain: 0) == nil)
    }
}
