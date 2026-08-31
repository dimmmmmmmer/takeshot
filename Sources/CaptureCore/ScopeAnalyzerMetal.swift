import CoreVideo
import Foundation
import Metal

/// The scope accumulation on the GPU.
///
/// # Why
///
/// The walk is 1024 x 270 samples a frame, and each one writes about thirty
/// times into four megabytes of maps — a histogram, four waveform difference
/// arrays, three colour sums and two scatter maps. Measured in release on the
/// development Mac: **22.2 ms for one 1080p pass**, against a 40 ms frame at
/// 25 fps. It runs on its own utility queue with latest-wins coalescing, so it
/// does not block the picture — but scattered writes over four megabytes evict
/// everything else from cache, and that is felt everywhere (owner: "при
/// включении скопов остальное приложение лагает здраво так", and: "почему-то в
/// резолве не лагают скопы" — Resolve computes its scopes on the GPU).
///
/// # What runs where, and why the split is there
///
/// The CPU still READS the frame. Unpacking `v210`, `r210` and `R12B` is
/// bit-twiddling against three packed layouts with their own stride rules, and
/// each of those rules is a hardware fact this project has already got wrong
/// once — porting them into a shader would be re-deriving them in a language
/// with no tests against a board. So the walk unpacks into a flat array of
/// samples, sequentially, which is a couple of milliseconds; the GPU does the
/// SCATTER, which is the twenty.
///
/// # The shape that makes it fit
///
/// One thread per COLUMN, walking its own 270 rows in order. That is not a
/// convenience: the waveform is a difference array whose segment depends on the
/// PREVIOUS sample in the same column, so the rows have to stay sequential. A
/// thread that owns a column owns every cell it writes — `[row * width + col]`
/// — so the whole waveform needs no atomics at all. Only the histogram and the
/// two scatter maps are shared, and those are `atomic_fetch_add`.
///
/// # What it does NOT do
///
/// `finish()` stays on the CPU. Softening, the log curves and the coloured
/// trace are passes over the finished maps rather than per-sample work — a
/// hundredth of the cost — and they are where the numbers become the picture,
/// which is the part worth keeping in one readable place.
///
/// # Precision, stated rather than assumed
///
/// Metal has no `double`. The luma weights, the chroma and the chromaticity
/// arithmetic are `float` here and `Double` on the CPU, so a sample sitting
/// exactly on a rounding boundary can land one code — or one cell — either
/// side of where the CPU puts it. That is one sample of 276 480 in a map the
/// operator reads as a density, and `ScopeAnalyzerParityTests` measures the
/// difference rather than assuming it: what is asserted is the RENDERED bytes,
/// which is what an operator actually looks at.
///
/// # When it is not there
///
/// No Metal device, no shader compile, no command queue — any of them and this
/// answers nil and `ScopeAnalyzer.analyze` walks the CPU path it always had.
/// A VM without a GPU is a real configuration (CI runs in one), and a scope
/// that vanishes there would be worse than a slow one.
public enum ScopeAnalyzerMetal {
    /// Built once, on first use. Compiling the shader costs tens of
    /// milliseconds and the result is reused for the life of the process.
    private static let shared = Backend()

    /// Whether this machine can run the GPU path at all.
    public static var isAvailable: Bool { shared.pipeline != nil }

    /// Whether the analyzer actually takes this path.
    ///
    /// On wherever there is a GPU, which is every Mac this app runs on. It is
    /// a variable rather than a constant for one reason: `ScopeGPUParityTests`
    /// turns it off to measure the two paths against each other on the same
    /// frame, which is the only way that comparison can be made.
    ///
    /// **The scopes are an instrument, so this was off until the two agreed.**
    /// They do: the histograms and the RGB waveforms are identical byte for
    /// byte, and the three maps that go through `float` differ by at most one
    /// code of 255. The first shape it had did not — a thread per COLUMN joined
    /// each sample to the one above it instead of the one beside it, which the
    /// histograms could not see and the waveform could.
    nonisolated(unsafe) public static var isEnabled = isAvailable

    /// Why not, for the diagnostics bundle. nil when it is available.
    public static var unavailableReason: String? { shared.failure }

    /// One sample as the walk unpacked it — the shader's `Sample`, laid out to
    /// match it byte for byte.
    struct Sample {
        var r: UInt16 = 0
        var g: UInt16 = 0
        var b: UInt16 = 0
        var luma: UInt16 = 0
        var cb: Float = 0
        var cr: Float = 0
    }

    /// The shader's `Params`, in the same order. Every number the two
    /// implementations share travels in here rather than being written twice.
    struct Params {
        /// Zeroed, then filled field by field — `Accumulator.metalParams` is
        /// the only builder, and a 25-argument initialiser there defeats the
        /// type checker outright.
        init() {}

        var columns: UInt32 = 0
        var rows: UInt32 = 0
        var waveWidth: UInt32 = 0
        var waveHeight: UInt32 = 0
        var vectorSize: UInt32 = 0
        var cieSize: UInt32 = 0
        var cieSpan: Float = 0
        var sampleLevels: UInt32 = 0
        var maxSpan: Int32 = 0
        var splitUnit: Int32 = 0
        var chromaGain: Float = 0
        var lumaR: Float = 0
        var lumaG: Float = 0
        var lumaB: Float = 0
        var m00: Float = 0, m01: Float = 0, m02: Float = 0
        var m10: Float = 0, m11: Float = 0, m12: Float = 0
        var m20: Float = 0, m21: Float = 0, m22: Float = 0
        var hasNativeLuma: UInt32 = 0
        var hasNativeChroma: UInt32 = 0
    }

    /// The maps the shader filled, as views into the GPU buffers.
    ///
    /// **Views and not arrays.** Building ten Swift arrays out of them was
    /// 15 MB of copying per frame on top of the 15 MB of allocation the
    /// buffers themselves cost — measured at 13.2 ms a pass against the CPU's
    /// 23.7, most of the remainder being that. These point into storage the
    /// backend owns and reuses, and they are valid only inside the `consume`
    /// closure `accumulate` hands them to.
    struct Maps {
        var diffY: UnsafeBufferPointer<Int32>
        var diffR: UnsafeBufferPointer<Int32>
        var diffG: UnsafeBufferPointer<Int32>
        var diffB: UnsafeBufferPointer<Int32>
        var sumR: UnsafeBufferPointer<Int32>
        var sumG: UnsafeBufferPointer<Int32>
        var sumB: UnsafeBufferPointer<Int32>
        var hist: UnsafeBufferPointer<Int32>
        var vector: UnsafeBufferPointer<Int32>
        var cie: UnsafeBufferPointer<Int32>
    }

    /// One pass: fill the samples, scatter them, read the maps.
    ///
    /// All three inside one call because all three touch storage the backend
    /// owns and reuses — allocating 20 MB of buffers per frame was most of what
    /// the first version of this cost. The lock is held across the whole thing,
    /// so two scope surfaces analysing at once take turns rather than sharing
    /// a sample buffer; a pass is a few milliseconds and the callers are
    /// already latest-wins coalesced.
    ///
    /// Returns false when there is no GPU path, which is the caller's cue to
    /// walk the CPU one.
    static func accumulate(_ request: Request,
                           fill: (UnsafeMutablePointer<Sample>) -> Void,
                           consume: (Maps) -> Void) -> Bool {
        shared.run(request, fill: fill, consume: consume)
    }

    /// One pass's inputs, as a value: how many samples are coming, the
    /// constants the shader reads, the linear-light table, and how big one
    /// waveform map is. Together rather than as arguments because they travel
    /// together and are decided in one place (`Accumulator.metalParams`).
    struct Request {
        var sampleCount: Int
        var params: Params
        var linear: [Float]
        var waveCells: Int
    }

    // MARK: - the device side

    /// Immutable after `init`, and the Metal objects it holds are documented
    /// as safe to use from several threads. The unchecked conformance is that
    /// sentence rather than an escape.
    private final class Backend: @unchecked Sendable {
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        let pipeline: MTLComputePipelineState?
        let failure: String?

        /// The buffers, built once and reused. Guarded by `lock`: two scope
        /// surfaces can analyse at the same time and they must not share a
        /// sample buffer.
        private let lock = NSLock()
        private var samples: MTLBuffer?
        private var linearBuffer: MTLBuffer?
        private var maps: [MTLBuffer] = []
        private var mapCells: [Int] = []

        init() {
            guard let device = MTLCreateSystemDefaultDevice() else {
                self.device = nil; queue = nil; pipeline = nil
                failure = "no Metal device"
                return
            }
            self.device = device
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: ScopeKernel.source,
                                                     options: nil)
                guard let function = library.makeFunction(name: "scope_accumulate") else {
                    pipeline = nil
                    failure = "the shader has no scope_accumulate"
                    return
                }
                pipeline = try device.makeComputePipelineState(function: function)
                failure = queue == nil ? "no command queue" : nil
            } catch {
                pipeline = nil
                failure = "the shader would not compile: \(error.localizedDescription)"
            }
        }

        /// A buffer of at least `bytes`, kept for next time.
        private func buffer(_ existing: inout MTLBuffer?, bytes: Int) -> MTLBuffer? {
            if let existing, existing.length >= bytes { return existing }
            existing = device?.makeBuffer(length: bytes,
                                          options: .storageModeShared)
            return existing
        }

        func run(_ request: Request,
                 fill: (UnsafeMutablePointer<Sample>) -> Void,
                 consume: (Maps) -> Void) -> Bool {
            guard let queue, request.sampleCount > 0 else { return false }
            lock.lock()
            defer { lock.unlock() }

            let wanted = Self.cellCounts(for: request)
            guard reserve(wanted, for: request),
                  let sampleBuffer = samples, let linearStorage = linearBuffer
            else { return false }

            fill(sampleBuffer.contents().bindMemory(
                to: Sample.self, capacity: request.sampleCount))
            request.linear.withUnsafeBytes {
                linearStorage.contents().copyMemory(from: $0.baseAddress!,
                                                    byteCount: $0.count)
            }

            guard let command = queue.makeCommandBuffer(),
                  encode(request, cells: wanted, into: command,
                         samples: sampleBuffer, linear: linearStorage)
            else { return false }
            command.commit()
            command.waitUntilCompleted()
            guard command.error == nil else { return false }

            func view(_ index: Int) -> UnsafeBufferPointer<Int32> {
                UnsafeBufferPointer(
                    start: maps[index].contents().bindMemory(
                        to: Int32.self, capacity: wanted[index]),
                    count: wanted[index])
            }
            consume(Maps(diffY: view(0), diffR: view(1), diffG: view(2),
                         diffB: view(3), sumR: view(4), sumG: view(5),
                         sumB: view(6), hist: view(7), vector: view(8),
                         cie: view(9)))
            return true
        }

        /// How many cells each of the ten maps needs, in the order the shader
        /// binds them.
        private static func cellCounts(for request: Request) -> [Int] {
            let wave = request.waveCells
            let vector = Int(request.params.vectorSize * request.params.vectorSize)
            let cie = Int(request.params.cieSize * request.params.cieSize)
            return [wave, wave, wave, wave, wave, wave, wave, 1024, vector, cie]
        }

        /// Make sure every buffer exists and is big enough, building only what
        /// has changed shape. Called under `lock`.
        private func reserve(_ wanted: [Int], for request: Request) -> Bool {
            guard let device else { return false }
            if mapCells != wanted {
                maps = wanted.compactMap {
                    device.makeBuffer(length: $0 * MemoryLayout<Int32>.stride,
                                      options: .storageModeShared)
                }
                mapCells = maps.count == wanted.count ? wanted : []
            }
            return mapCells == wanted
                && buffer(&samples, bytes: request.sampleCount
                              * MemoryLayout<Sample>.stride) != nil
                && buffer(&linearBuffer, bytes: request.linear.count
                              * MemoryLayout<Float>.stride) != nil
        }

        /// Zero the maps and dispatch the kernel over them.
        private func encode(_ request: Request, cells: [Int],
                            into command: MTLCommandBuffer,
                            samples sampleBuffer: MTLBuffer,
                            linear: MTLBuffer) -> Bool {
            guard let pipeline,
                  let blit = command.makeBlitCommandEncoder() else { return false }
            // Zeroed ON the GPU: a `memset` of 15 MB per frame from this side
            // is most of a millisecond, and a blit runs while nothing else is.
            for (index, map) in maps.enumerated() {
                blit.fill(buffer: map,
                          range: 0..<(cells[index] * MemoryLayout<Int32>.stride),
                          value: 0)
            }
            blit.endEncoding()

            guard let encoder = command.makeComputeCommandEncoder()
            else { return false }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(sampleBuffer, offset: 0, index: 0)
            encoder.setBuffer(linear, offset: 0, index: 1)
            for (index, map) in maps.enumerated() {
                encoder.setBuffer(map, offset: 0, index: index + 2)
            }
            var parameters = request.params
            encoder.setBytes(&parameters, length: MemoryLayout<Params>.stride,
                             index: 12)
            // One thread per SAMPLE: the segment runs from the sample BESIDE
            // this one, which is a read and not a chain, so nothing here is
            // sequential. See the kernel's note.
            let threads = Int(request.params.rows) * Int(request.params.columns)
            let width = min(pipeline.maxTotalThreadsPerThreadgroup, threads)
            encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                    threadsPerThreadgroup:
                                        MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            return true
        }
    }
}
