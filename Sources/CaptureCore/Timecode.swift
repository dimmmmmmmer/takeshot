import Foundation

/// SMPTE-таймкод. `fps` — номинальная частота нумерации кадров (24, 25, 30, 60...);
/// для 29.97/59.94 drop-frame используется `fps` 30/60 + `isDropFrame`.
public struct Timecode: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var fps: Int
    public var isDropFrame: Bool

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, fps: Int, isDropFrame: Bool = false) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.fps = fps
        self.isDropFrame = isDropFrame
    }

    /// Реальный порядковый номер кадра с начала суток (учитывает drop-frame),
    /// т.е. у двух последовательных кадров записи разница всегда ровно 1 —
    /// в том числе через минутную границу DF.
    public var frameNumber: Int {
        let nominal = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        guard isDropFrame, fps % 30 == 0 else { return nominal }
        let dropPerMinute = fps / 15 // 2 для 30, 4 для 60
        let totalMinutes = hours * 60 + minutes
        return nominal - dropPerMinute * (totalMinutes - totalMinutes / 10)
    }

    /// Обратное преобразование: реальный номер кадра → метка таймкода.
    public init(frameNumber: Int, fps: Int, isDropFrame: Bool = false) {
        var fn = max(0, frameNumber)
        if isDropFrame, fps % 30 == 0 {
            let dropPerMinute = fps / 15
            let framesPerMinute = fps * 60 - dropPerMinute        // все минуты, кроме каждой 10-й
            let framesPer10Minutes = fps * 600 - dropPerMinute * 9
            let tenMinuteBlocks = fn / framesPer10Minutes
            let rem = fn % framesPer10Minutes
            if rem > dropPerMinute {
                fn += dropPerMinute * 9 * tenMinuteBlocks
                    + dropPerMinute * ((rem - dropPerMinute) / framesPerMinute)
            } else {
                fn += dropPerMinute * 9 * tenMinuteBlocks
            }
        }
        self.frames = fn % fps
        fn /= fps
        self.seconds = fn % 60
        fn /= 60
        self.minutes = fn % 60
        self.hours = (fn / 60) % 24
        self.fps = fps
        self.isDropFrame = isDropFrame
    }

    public func advanced(by n: Int) -> Timecode {
        Timecode(frameNumber: frameNumber + n, fps: fps, isDropFrame: isDropFrame)
    }

    public var description: String {
        let sep = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// Вариант для имён файлов (без двоеточий).
    public var fileNameSafe: String {
        String(format: "%02d.%02d.%02d.%02d", hours, minutes, seconds, frames)
    }
}
