import Foundation

/// Формат входного сигнала, определённый капчур-платой.
public struct CaptureFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double        // фактическая (23.976, 25, 29.97...)
    public var timecodeFPS: Int         // номинальная нумерация TC (24, 25, 30...)
    public var isDropFrame: Bool
    public var name: String             // человекочитаемо: "1080p25"

    public init(width: Int, height: Int, frameRate: Double, timecodeFPS: Int,
                isDropFrame: Bool = false, name: String) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.timecodeFPS = timecodeFPS
        self.isDropFrame = isDropFrame
        self.name = name
    }
}

/// Кодек записи.
public enum CaptureCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case proResProxy = "ProRes 422 Proxy"
    case proResLT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proResHQ = "ProRes 422 HQ"
    case h264 = "H.264"
    case hevc = "HEVC"

    public var id: String { rawValue }
}

/// Дубль — один непрерывный отрезок записи камеры, один файл на диске.
public struct Take: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var displayName: String
    public var scene: String
    public var roll: String
    public var takeNumber: Int
    public var startTimecode: Timecode?
    public var durationSeconds: Double
    public var isCircled: Bool          // "circle take" — отмеченный удачный дубль
    public var recordedAt: Date

    public init(id: UUID = UUID(), url: URL, displayName: String, scene: String,
                roll: String = "", takeNumber: Int, startTimecode: Timecode?,
                durationSeconds: Double, isCircled: Bool = false, recordedAt: Date) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.scene = scene
        self.roll = roll
        self.takeNumber = takeNumber
        self.startTimecode = startTimecode
        self.durationSeconds = durationSeconds
        self.isCircled = isCircled
        self.recordedAt = recordedAt
    }
}

/// Режим детекции начала/конца дубля.
public enum RecDetectionMode: String, CaseIterable, Codable, Sendable {
    case auto           // VANC-триггер, если распознан, + бегущий таймкод
    case timecodeRun    // только по бегущему TC (камера в Rec Run)
    case manual         // только кнопка в приложении
}

/// Настройки приложения (персистятся в UserDefaults как JSON).
public struct CaptureSettings: Codable, Equatable, Sendable {
    public var codec: CaptureCodec = .proRes422
    public var namingTemplate: String = "{prefix}_{cam}_{roll}_C{clip}"
    public var destinationPath: String = NSSearchPathForDirectoriesInDomains(
        .moviesDirectory, .userDomainMask, true).first.map { $0 + "/TakeShot" } ?? "~/Movies/TakeShot"
    public var detectionMode: RecDetectionMode = .auto
    public var startDebounceFrames: Int = 4
    public var stopDebounceFrames: Int = 12
    public var projectName: String = ""
    public var cameraLabel: String = "A"
    /// Язык интерфейса: "en" (приоритетный), "ru", nil — системный.
    /// Optional — чтобы старые сохранённые настройки декодировались без миграции.
    public var appLanguage: String?
    /// Пре-ролл в секундах: сколько кадров ДО старта записи камеры включать в дубль.
    /// Optional по той же причине; эффективное значение — preRollSecondsEffective.
    public var preRollSeconds: Double?
    /// Тема интерфейса: "light" / "dark" / nil — системная.
    public var appearance: String?
    /// Цвет подложки плеера, hex "#RRGGBB"; nil — чёрный.
    public var playerBackgroundHex: String?

    public var preRollSecondsEffective: Double { preRollSeconds ?? 1.0 }

    public init() {}

    private static let defaultsKey = "TakeShot.CaptureSettings"

    public static func loaded(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        // миграция со старого дефолтного шаблона на Prefix/Cam/Roll/Clip
        if settings.namingTemplate == "{scene}_T{take}_{cam}_{tc}" {
            settings.namingTemplate = CaptureSettings().namingTemplate
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
