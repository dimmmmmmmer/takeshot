import Testing
@testable import TakeShotKit

/// Placeholder proving the application layer is reachable from tests at all —
/// replaced by the real session tests below.
struct SmokeTests {
    @Test func moduleIsImportable() {
        #expect(MockCaptureBackend.deviceID == "mock-source")
    }
}
