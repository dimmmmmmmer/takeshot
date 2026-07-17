import Foundation

/// SMPTE 291M ancillary-пакет (сырые данные из VANC).
public struct AncillaryPacket: Sendable, Equatable {
    public var did: UInt8
    public var sdid: UInt8
    public var lineNumber: UInt32
    public var data: [UInt8]

    public init(did: UInt8, sdid: UInt8, lineNumber: UInt32 = 0, data: [UInt8]) {
        self.did = did
        self.sdid = sdid
        self.lineNumber = lineNumber
        self.data = data
    }
}

/// Разбор известных VANC-пакетов.
///
/// Сейчас распознаётся Blackmagic SDI Camera Control Protocol (DID 0x51 / SDID 0x53):
/// команда Transport Mode (категория 10, параметр 1) несёт режим транспорта —
/// 2 = record, иначе стоп. Остальные пакеты просто пролетают в VANC-монитор,
/// где по их DID/SDID и хексу можно реверсить вендорские форматы на площадке.
public enum VancParser {
    public static let blackmagicDID: UInt8 = 0x51
    public static let cameraControlSDID: UInt8 = 0x53
    public static let tallySDID: UInt8 = 0x52

    /// REC-триггер из пачки пакетов кадра (nil — триггера нет).
    public static func recTrigger(in packets: [AncillaryPacket]) -> VancTrigger? {
        for packet in packets
        where packet.did == blackmagicDID && packet.sdid == cameraControlSDID {
            if let trigger = parseCameraControl(packet.data) {
                return trigger
            }
        }
        return nil
    }

    /// Blackmagic SDI Camera Control: поток команд вида
    /// [dest, len, cmdID=0, reserved][category, parameter, dataType, operation, data...],
    /// каждая команда выровнена на 4 байта. Категория 10 (Media), параметр 1
    /// (Transport Mode): data[0] — режим: 0 preview, 1 play, 2 record.
    static func parseCameraControl(_ data: [UInt8]) -> VancTrigger? {
        var trigger: VancTrigger?
        var offset = 0
        while offset + 8 <= data.count {
            let commandLength = Int(data[offset + 1])
            guard commandLength >= 4 else { break }
            let category = data[offset + 4]
            let parameter = data[offset + 5]
            if category == 10, parameter == 1, offset + 8 < data.count {
                let transportMode = data[offset + 8]
                trigger = (transportMode == 2) ? .recordStart : .recordStop
            }
            // заголовок (4) + данные команды, выровненные вверх до кратности 4
            let padded = (commandLength + 3) & ~3
            offset += 4 + padded
        }
        return trigger
    }
}

/// Агрегированная статистика по типам VANC-пакетов — для монитора в UI.
public struct VancPacketStat: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var key: String            // "51/53"
    public var did: UInt8
    public var sdid: UInt8
    public var count: Int
    public var lastLine: UInt32
    public var lastDataHex: String    // первые байты последнего пакета

    public init(did: UInt8, sdid: UInt8, count: Int, lastLine: UInt32, lastDataHex: String) {
        self.key = String(format: "%02X/%02X", did, sdid)
        self.did = did
        self.sdid = sdid
        self.count = count
        self.lastLine = lastLine
        self.lastDataHex = lastDataHex
    }
}
