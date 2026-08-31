import Testing

@testable import CaptureCore

/// Whether the GPU path can exist on this machine at all.
///
/// Its own test because the answer is a fact about the HOST, not about the
/// code: a VM with no GPU is a real configuration (CI runs in one), and the
/// analyzer has to fall back rather than fail there. What this pins is that
/// when Metal IS available, the shader compiles — a shader that does not is a
/// silent fallback to the slow path, which looks like nothing at all.
struct ScopeMetalAvailabilityTests {
    @Test func theShaderCompilesWhereThereIsAGPU() {
        if ScopeAnalyzerMetal.isAvailable {
            #expect(ScopeAnalyzerMetal.unavailableReason == nil)
        } else {
            let reason = ScopeAnalyzerMetal.unavailableReason
            #expect(reason != nil, "unavailable for no stated reason")
            // A machine with no device is expected. A shader that does not
            // build is a defect wearing the same clothes, so the two are told
            // apart here rather than both passing quietly.
            #expect(reason?.hasPrefix("shader:") != true,
                    "the shader failed to compile: \(reason ?? "")")
            print("no GPU path here: \(reason ?? "")")
        }
    }
}
