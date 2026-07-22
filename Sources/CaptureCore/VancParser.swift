import Foundation

/// A SMPTE 291M ancillary packet (raw data from VANC).
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

/// Parses known VANC packets.
///
/// Currently recognizes the Blackmagic SDI Camera Control Protocol (DID 0x51 /
/// SDID 0x53): the Transport Mode command (category 10, parameter 1) carries the
/// transport mode — 2 = record, otherwise stop. Other packets just pass through
/// to the VANC monitor, where their DID/SDID and hex let you reverse-engineer
/// vendor formats on set.
public enum VancParser {
    public static let blackmagicDID: UInt8 = 0x51
    public static let cameraControlSDID: UInt8 = 0x53
    public static let tallySDID: UInt8 = 0x52

    /// REC trigger from a frame's packet batch (nil — no trigger).
    public static func recTrigger(in packets: [AncillaryPacket]) -> VancTrigger? {
        for packet in packets
        where packet.did == blackmagicDID && packet.sdid == cameraControlSDID {
            if let trigger = parseCameraControl(packet.data) {
                return trigger
            }
        }
        return nil
    }

    /// Blackmagic SDI Camera Control: a stream of commands shaped like
    /// [dest, len, cmdID=0, reserved][category, parameter, dataType, operation, data...],
    /// each command aligned to 4 bytes. Category 10 (Media), parameter 1
    /// (Transport Mode): data[0] is the mode: 0 preview, 1 play, 2 record.
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
            // header (4) + command data, padded up to a multiple of 4
            let padded = (commandLength + 3) & ~3
            offset += 4 + padded
        }
        return trigger
    }
}

/// Aggregated stats per VANC packet type — for the UI monitor.
public struct VancPacketStat: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var key: String            // "51/53"
    public var did: UInt8
    public var sdid: UInt8
    public var count: Int
    public var lastLine: UInt32
    public var lastDataHex: String    // first bytes of the last packet

    public init(did: UInt8, sdid: UInt8, count: Int, lastLine: UInt32, lastDataHex: String) {
        self.key = String(format: "%02X/%02X", did, sdid)
        self.did = did
        self.sdid = sdid
        self.count = count
        self.lastLine = lastLine
        self.lastDataHex = lastDataHex
    }
}
