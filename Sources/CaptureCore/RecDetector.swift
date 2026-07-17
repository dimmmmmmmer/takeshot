import Foundation

/// Явный REC-триггер, распознанный в VANC-пакетах (вендор-специфично).
public enum VancTrigger: Equatable, Sendable {
    case recordStart
    case recordStop
}

/// Один кадр входного сигнала глазами детектора.
public struct FrameSample: Sendable {
    public var index: Int               // сквозной счётчик кадров захвата
    public var timecode: Timecode?
    public var vancTrigger: VancTrigger?

    public init(index: Int, timecode: Timecode?, vancTrigger: VancTrigger? = nil) {
        self.index = index
        self.timecode = timecode
        self.vancTrigger = vancTrigger
    }
}

public enum RecEvent: Equatable, Sendable {
    /// Камера начала запись. `atIndex` — кадр фактического старта (первый кадр,
    /// на котором TC пошёл), обычно раньше кадра, на котором сработал дебаунс —
    /// контроллер добирает эти кадры из пре-ролл-буфера.
    case started(atIndex: Int, timecode: Timecode?)
    /// Камера остановила запись. `atIndex` — последний кадр дубля.
    case stopped(atIndex: Int)
}

public struct RecDetectorConfig: Equatable, Sendable {
    /// Сколько кадров подряд TC должен идти, чтобы объявить REC (фильтр от глитчей).
    public var startDebounceFrames: Int
    /// Сколько кадров подряд TC должен стоять/отсутствовать, чтобы объявить стоп.
    public var stopDebounceFrames: Int

    public init(startDebounceFrames: Int = 4, stopDebounceFrames: Int = 12) {
        self.startDebounceFrames = max(1, startDebounceFrames)
        self.stopDebounceFrames = max(1, stopDebounceFrames)
    }
}

/// Детектор REC-состояния камеры по бегущему таймкоду (универсально, камера в Rec Run)
/// и по VANC-триггерам (приоритетнее, если распознаны).
///
/// Чистая state machine без зависимостей от железа — вся логика тестируется на синтетике.
public final class RecDetector {
    public private(set) var isRecording = false

    private let config: RecDetectorConfig
    private var lastTimecode: Timecode?
    private var lastIndex: Int = -1

    // накопление старта
    private var advanceRunLength = 0
    private var runStartIndex = 0
    private var runStartTimecode: Timecode?

    // накопление стопа
    private var stallRunLength = 0
    private var stallStartIndex = 0

    public init(config: RecDetectorConfig = RecDetectorConfig()) {
        self.config = config
    }

    public func reset() {
        isRecording = false
        lastTimecode = nil
        lastIndex = -1
        advanceRunLength = 0
        stallRunLength = 0
    }

    public func process(_ sample: FrameSample) -> RecEvent? {
        defer {
            lastTimecode = sample.timecode ?? lastTimecode
            lastIndex = sample.index
        }

        // VANC-триггер — явное знание, срабатывает без дебаунса.
        if let trigger = sample.vancTrigger {
            switch trigger {
            case .recordStart where !isRecording:
                beginRecording()
                return .started(atIndex: sample.index, timecode: sample.timecode)
            case .recordStop where isRecording:
                endRecording()
                return .stopped(atIndex: sample.index)
            default:
                break
            }
        }

        switch movement(of: sample) {
        case .advancing:
            stallRunLength = 0
            if !isRecording {
                if advanceRunLength == 0 {
                    // первый кадр движения — предыдущий кадр уже часть дубля
                    // (TC "пошёл" между прошлым и текущим кадром)
                    runStartIndex = max(0, sample.index - 1)
                    runStartTimecode = lastTimecode
                }
                advanceRunLength += 1
                if advanceRunLength >= config.startDebounceFrames {
                    beginRecording()
                    return .started(atIndex: runStartIndex, timecode: runStartTimecode)
                }
            }

        case .stalled:
            advanceRunLength = 0
            if isRecording {
                if stallRunLength == 0 { stallStartIndex = sample.index }
                stallRunLength += 1
                if stallRunLength >= config.stopDebounceFrames {
                    endRecording()
                    return .stopped(atIndex: max(0, stallStartIndex - 1))
                }
            }

        case .discontinuity:
            // скачок TC: при записи — камера остановилась (и, возможно, тут же
            // начала новый дубль — его подберёт следующая серия advancing-кадров)
            advanceRunLength = 0
            if isRecording {
                endRecording()
                return .stopped(atIndex: max(0, sample.index - 1))
            }

        case .noData:
            advanceRunLength = 0
            if isRecording {
                if stallRunLength == 0 { stallStartIndex = sample.index }
                stallRunLength += 1
                if stallRunLength >= config.stopDebounceFrames {
                    endRecording()
                    return .stopped(atIndex: max(0, stallStartIndex - 1))
                }
            }
        }

        return nil
    }

    // MARK: - private

    private enum Movement {
        case advancing      // TC вырос ровно на 1 кадр
        case stalled        // TC не изменился
        case discontinuity  // TC скакнул (вперёд/назад больше чем на 1)
        case noData         // TC отсутствует
    }

    private func movement(of sample: FrameSample) -> Movement {
        guard let tc = sample.timecode else { return .noData }
        guard let last = lastTimecode else {
            // первый TC — точка отсчёта, движения ещё нет
            return .stalled
        }
        // капчур может отдавать один TC на пару кадров (PsF) — считаем повтор stall,
        // а шаг ровно в 1 кадр — движением
        let delta = tc.frameNumber - last.frameNumber
        switch delta {
        case 0: return .stalled
        case 1: return .advancing
        default: return .discontinuity
        }
    }

    private func beginRecording() {
        isRecording = true
        advanceRunLength = 0
        stallRunLength = 0
    }

    private func endRecording() {
        isRecording = false
        advanceRunLength = 0
        stallRunLength = 0
    }
}
