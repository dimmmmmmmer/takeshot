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

    /// **The shipping default is the GPU path**, wherever there is a GPU.
    ///
    /// Pinned because nothing else does: the parity suite is the only thing
    /// that touches the switch, and the first version of it restored `false`
    /// rather than the default. `swift test --no-parallel` is one process, so
    /// that handed every scope suite scheduled afterwards the CPU path — the
    /// suites that are supposed to be exercising what ships.
    @Test func theShippingDefaultIsWhateverTheMachineCanDo() {
        #expect(ScopeAnalyzerMetal.isEnabled == ScopeAnalyzerMetal.isAvailable,
                """
                the GPU path is \(ScopeAnalyzerMetal.isEnabled ? "on" : "off") \
                on a machine that \(ScopeAnalyzerMetal.isAvailable ? "can" : "cannot") \
                run it — a suite left the switch where it found it convenient
                """)
    }
}
