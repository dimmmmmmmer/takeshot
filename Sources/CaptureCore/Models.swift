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

/// Оценка дубля: удачный (Good Take в Resolve) / брак / без отметки.
public enum TakeRating: String, Equatable, Sendable {
    case none
    case good
    case bad
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
    public var rating: TakeRating       // good/bad take (в CSV — Good Take + пометка NG)
    public var recordedAt: Date

    public init(id: UUID = UUID(), url: URL, displayName: String, scene: String,
                roll: String = "", takeNumber: Int, startTimecode: Timecode?,
                durationSeconds: Double, rating: TakeRating = .none, recordedAt: Date) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.scene = scene
        self.roll = roll
        self.takeNumber = takeNumber
        self.startTimecode = startTimecode
        self.durationSeconds = durationSeconds
        self.rating = rating
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
    public var namingTemplate: String = "{prefix}_{cam}{roll}C{clip}_{postfix}"
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
    /// Цвет фона окна приложения, hex; nil — системный.
    public var appBackgroundHex: String?
    /// Постфикс имени файла ({postfix} в шаблоне).
    public var postfix: String?
    /// Сколько первых аудиоканалов писать в файл (устарело, заменено маской).
    public var recordChannelCount: Int?
    /// Битовая маска записываемых каналов (бит i = канал i); nil — все.
    public var audioChannelMask: Int?
    /// UID аудиоустройства для вывода плейбека; nil — системное.
    public var playbackAudioDeviceUID: String?
    /// Акцентный цвет контролов, hex; nil — нейтральный серый.
    public var accentHex: String?
    /// DeckLink-устройство для видеовыхода на монитор (SDI/HDMI); nil — выкл.
    public var monitorDeviceID: String?
    /// Число цифр в номере клипа (C01 / C001 / C0001); nil — 2.
    public var clipPadWidth: Int?
    /// Имя файла выбранного LUT (в папке LUTs приложения); nil — без LUT.
    public var lutFileName: String?
    /// Применять LUT к превью (лайв и плейбек).
    public var lutPreviewEnabled: Bool?
    /// Запекать LUT в записываемый файл (иначе пишется чистый сигнал).
    public var lutRecordEnabled: Bool?
    /// Интенсивность LUT 0…1 (микс с оригиналом); nil — 1.
    public var lutIntensity: Double?
    /// Цветовые теги видео: "709" (nclc 1-1-1, дефолт), "601", "2020".
    public var colorTagPreset: String?
    /// Обработка уровней видео на пиксели: nil/"auto" — не трогать,
    /// "limited" — сжать full→legal 16-235, "full" — растянуть legal→0-255.
    public var videoLevels: String?

    public var clipPadWidthEffective: Int { min(4, max(2, clipPadWidth ?? 2)) }

    public var preRollSecondsEffective: Double { preRollSeconds ?? 1.0 }

    public init() {}

    private static let defaultsKey = "TakeShot.CaptureSettings"

    public static func loaded(from defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return CaptureSettings() }
        // миграции дефолтных шаблонов прошлых версий
        if ["{scene}_T{take}_{cam}_{tc}",
            "{prefix}_{cam}_{roll}_C{clip}",
            "{prefix}_{cam}_{roll}_C{clip}_{postfix}"].contains(settings.namingTemplate) {
            settings.namingTemplate = CaptureSettings().namingTemplate
        }
        // пресеты до появления вендорских форматов дат ({date6}/{date4}/{time4})
        let presetMigrations = [
            "{cam}{roll}C{clip}_{date}_{postfix}": "{cam}{roll}C{clip}_{date6}_{postfix}",
            "{cam}{roll}_C{clip}_{date}_{postfix}": "{cam}{roll}_C{clip}_{date4}{postfix}",
            "{cam}{roll}C{clip}_{date}{postfix}": "{cam}{roll}C{clip}_{date6}{postfix}",
            "{cam}{roll}_{date}_C{clip}": "{cam}{roll}_{date4}{time4}_C{clip}",
        ]
        if let migrated = presetMigrations[settings.namingTemplate] {
            settings.namingTemplate = migrated
        }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}


/// Инкремент/декремент полей нейминга (ролл «001» → «002», камера A → B).
public enum FieldStepper {
    /// Меняет хвостовые цифры строки, сохраняя ведущие нули: "001"+1 → "002",
    /// "A12"+1 → "A13". Без цифр в хвосте строка не меняется.
    public static func stepTrailingNumber(_ value: String, by delta: Int) -> String {
        guard let range = value.range(of: "[0-9]+$", options: .regularExpression),
              let number = Int(value[range]) else { return value }
        let width = value.distance(from: range.lowerBound, to: range.upperBound)
        let next = max(0, number + delta)
        return value[..<range.lowerBound] + String(format: "%0\(width)d", next)
    }

    /// Меняет последнюю букву A-Z по алфавиту (с циклом): "A"+1 → "B", "Z"+1 → "A".
    public static func stepLetter(_ value: String, by delta: Int) -> String {
        guard let last = value.unicodeScalars.last,
              last.value >= 65, last.value <= 90 else { return value }
        let index = Int(last.value) - 65
        let next = ((index + delta) % 26 + 26) % 26
        return String(value.unicodeScalars.dropLast())
            + String(UnicodeScalar(UInt8(65 + next)))
    }
}
