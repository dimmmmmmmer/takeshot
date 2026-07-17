import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureCore

/// End-to-end тест конвейера без железа: синтетический сигнал с Rec Run-таймкодом
/// проходит через детектор, writer и именование — на диске появляется готовый дубль.
struct CapturePipelineTests {
    private func makePixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &pixelBuffer)
        return pixelBuffer!
    }

    @Test func autoTakeFromRunningTimecodeProducesFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.namingTemplate = "{scene}_T{take}_{tc}"
        settings.projectName = "Test"
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0 // пре-ролл проверяется отдельным тестом

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "7", takeNumber: 2))

        var finishedTakes: [Take] = []
        var recStates: [Bool] = []
        try await confirmation("дубль закрыт") { takeDone in
            pipeline.onTakeFinished = { take in
                finishedTakes.append(take)
                takeDone()
            }
            pipeline.onRecStateChanged = { recStates.append($0) }

            pipeline.handleFormat(CaptureFormat(
                width: 640, height: 360, frameRate: 25, timecodeFPS: 25, name: "test"))

            let pixelBuffer = makePixelBuffer()
            var tc = Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0, fps: 25)
            var frame = 0

            // темп ~8мс/кадр: без него синтетика обгоняет энкодер и кадры дропаются
            // (в живом захвате кадры приходят с частотой сигнала)
            func push(_ timecode: Timecode) async throws {
                frame += 1
                pipeline.handleFrame(
                    pixelBuffer: pixelBuffer,
                    pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                    timecode: timecode, vancTrigger: nil)
                try await Task.sleep(for: .milliseconds(8))
            }

            // standby: TC стоит
            for _ in 0..<10 { try await push(tc) }
            // «камера пишет»: TC бежит 50 кадров (2 секунды)
            for _ in 0..<50 {
                tc = tc.advanced(by: 1)
                try await push(tc)
            }
            // стоп: TC снова стоит
            for _ in 0..<10 { try await push(tc) }

            // конвейер обрабатывает асинхронно — ждём событие завершения дубля
            for _ in 0..<100 where finishedTakes.isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let take = try #require(finishedTakes.first)
        #expect(recStates.contains(true) && recStates.last == false)
        #expect(take.scene == "7")
        #expect(take.takeNumber == 2)

        // имя по шаблону: сцена, номер дубля и стартовый TC (11:00:00:00 ± пре-ролл)
        #expect(take.displayName.hasPrefix("7_T02_11.00.00"))
        // папка: проект/дата/сцена
        #expect(take.url.path.contains("Test/"))
        #expect(take.url.path.hasSuffix(".mov"))

        // файл дописывается асинхронно после события — подождём его появления
        var fileExists = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: take.url.path) {
                fileExists = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fileExists, "файл дубля должен существовать: \(take.url.path)")

        // и это валидный ролик ~2 сек с видео- и timecode-треками
        let asset = AVURLAsset(url: take.url)
        let duration = try await asset.load(.duration)
        // допуск широкий: под нагрузкой (параллельные тесты, CI) энкодер может
        // дропнуть часть синтетических кадров — важно, что дубль есть и он ~2 сек
        #expect(duration.seconds > 1.2 && duration.seconds < 2.6)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        let tcTracks = try await asset.loadTracks(withMediaType: .timecode)
        #expect(tcTracks.count == 1)
    }

    @Test func preRollIncludesFramesBeforeRecStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0.8 // 20 кадров при 25 fps

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "1", takeNumber: 1))
        var finishedTakes: [Take] = []
        pipeline.onTakeFinished = { finishedTakes.append($0) }

        pipeline.handleFormat(CaptureFormat(
            width: 640, height: 360, frameRate: 25, timecodeFPS: 25, name: "test"))
        let pixelBuffer = makePixelBuffer()
        var tc = Timecode(hours: 12, minutes: 0, seconds: 0, frames: 0, fps: 25)
        var frame = 0
        func push(_ timecode: Timecode) async throws {
            frame += 1
            pipeline.handleFrame(
                pixelBuffer: pixelBuffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: timecode, vancTrigger: nil)
            try await Task.sleep(for: .milliseconds(8))
        }

        // долгий standby — буфер пре-ролла успевает наполниться
        for _ in 0..<30 { try await push(tc) }
        // запись 50 кадров, затем стоп
        for _ in 0..<50 {
            tc = tc.advanced(by: 1)
            try await push(tc)
        }
        for _ in 0..<10 { try await push(tc) }

        for _ in 0..<100 where finishedTakes.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let take = try #require(finishedTakes.first)

        var fileExists = false
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: take.url.path) {
                fileExists = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fileExists)

        // 50 кадров записи + ~4 хвостовых + 20 пре-ролла ≈ 74 кадра ≈ 2.96 c;
        // без пре-ролла было бы ~2.2 с — проверяем, что кадры до REC вошли
        let asset = AVURLAsset(url: take.url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 2.6 && duration.seconds < 3.4,
                "duration=\(duration.seconds)")
    }

    @Test func manualModeIgnoresRunningTimecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .manual

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "1", takeNumber: 1))
        var recStarted = false
        pipeline.onRecStateChanged = { if $0 { recStarted = true } }

        pipeline.handleFormat(CaptureFormat(
            width: 640, height: 360, frameRate: 25, timecodeFPS: 25, name: "test"))
        let pixelBuffer = makePixelBuffer()
        var tc = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for frame in 1...30 {
            tc = tc.advanced(by: 1)
            pipeline.handleFrame(
                pixelBuffer: pixelBuffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: tc, vancTrigger: nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recStarted, "в ручном режиме бегущий TC не должен запускать запись")
    }
}
