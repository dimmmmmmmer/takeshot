import Testing
@testable import CaptureCore

struct VancParserTests {
    /// Команда Transport Mode: заголовок [dest=255(broadcast), len, cmd=0, res]
    /// + [category=10, parameter=1, type=1, operation=0, mode, ...padding]
    private func transportPacket(mode: UInt8) -> AncillaryPacket {
        AncillaryPacket(did: 0x51, sdid: 0x53, data: [
            255, 6, 0, 0,       // dest, command length (4 команды + 2 данных → 6), id, reserved
            10, 1, 1, 0,        // категория Media, параметр Transport Mode, тип, операция
            mode, 0, 0, 0,      // режим + выравнивание
        ])
    }

    @Test func recordModeYieldsStartTrigger() {
        let trigger = VancParser.recTrigger(in: [transportPacket(mode: 2)])
        #expect(trigger == .recordStart)
    }

    @Test func previewModeYieldsStopTrigger() {
        let trigger = VancParser.recTrigger(in: [transportPacket(mode: 0)])
        #expect(trigger == .recordStop)
    }

    @Test func unrelatedPacketsYieldNothing() {
        let packets = [
            AncillaryPacket(did: 0x61, sdid: 0x01, data: [1, 2, 3]),        // CEA-708
            AncillaryPacket(did: 0x51, sdid: 0x52, data: [0, 0, 0, 0]),     // tally
            AncillaryPacket(did: 0x51, sdid: 0x53, data: [255, 4, 0, 0,
                                                          4, 0, 1, 0]),     // lens category
        ]
        #expect(VancParser.recTrigger(in: packets) == nil)
    }

    @Test func malformedPacketDoesNotCrash() {
        let packets = [
            AncillaryPacket(did: 0x51, sdid: 0x53, data: []),
            AncillaryPacket(did: 0x51, sdid: 0x53, data: [255]),
            AncillaryPacket(did: 0x51, sdid: 0x53, data: [255, 200, 0]),
        ]
        #expect(VancParser.recTrigger(in: packets) == nil)
    }

    @Test func secondCommandInGroupIsParsed() {
        // первая команда — линза (категория 0), вторая — transport record
        let data: [UInt8] = [
            255, 6, 0, 0, 0, 3, 128, 0, 0, 0, 0, 0,  // lens focus (len 6 → padded 8)
            255, 6, 0, 0, 10, 1, 1, 0, 2, 0, 0, 0,   // transport mode = record
        ]
        let trigger = VancParser.recTrigger(
            in: [AncillaryPacket(did: 0x51, sdid: 0x53, data: data)])
        #expect(trigger == .recordStart)
    }
}
