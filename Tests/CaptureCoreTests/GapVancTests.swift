import Testing
@testable import CaptureCore

/// The VANC shapes a real board actually delivers, which `VancParserTests` does
/// not cover: the zero padding that follows the last command inside a fixed-size
/// ancillary packet, a truncated command at the end of the buffer, and a
/// declared length that runs past the data.
///
/// This parser decides when a take starts. A false trigger records the rehearsal
/// and a missed one loses the take, and neither is visible until the card comes
/// off set — so every malformed shape has to be pinned, not just the clean one.
struct GapVancTests {
    private let did = VancParser.blackmagicDID
    private let sdid = VancParser.cameraControlSDID

    /// dest, length, id, reserved | category, parameter, type, operation, data…
    private func transportCommand(mode: UInt8) -> [UInt8] {
        [255, 6, 0, 0, 10, 1, 1, 0, mode, 0, 0, 0]
    }

    /// Camera control packets come out of the board at a fixed size, so a valid
    /// command is normally followed by zero padding. Length 0 there is not a
    /// command — the parser must stop, and must keep what it already found.
    @Test func zeroPaddingAfterACommandKeepsTheTrigger() {
        let data = transportCommand(mode: 2) + [UInt8](repeating: 0, count: 24)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(did: did, sdid: sdid,
                                                           data: data)])
                == .recordStart)
    }

    @Test func aPacketOfNothingButPaddingYieldsNoTrigger() {
        let data = [UInt8](repeating: 0, count: 32)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(did: did, sdid: sdid,
                                                           data: data)]) == nil)
    }

    /// Transport mode 1 is Play — a camera playing back its card is not
    /// recording, and reading it as a start would open a take over playback.
    @Test func playModeReadsAsStop() {
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: transportCommand(mode: 1))]) == .recordStop)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: transportCommand(mode: 0))]) == .recordStop)
    }

    /// Within one packet the parser walks every command, so the camera's latest
    /// statement of its transport mode is the one that counts.
    @Test func theLastTransportCommandInAPacketWins() {
        let startThenStop = transportCommand(mode: 2) + transportCommand(mode: 0)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: startThenStop)]) == .recordStop)

        let stopThenStart = transportCommand(mode: 0) + transportCommand(mode: 2)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: stopThenStart)]) == .recordStart)
    }

    /// A command header with no data byte behind it must not read whatever
    /// happens to sit past the end of the buffer.
    @Test func aTransportCommandWithNoDataByteYieldsNothing() {
        // exactly 8 bytes: header + category/parameter/type/operation, no mode
        let truncated: [UInt8] = [255, 5, 0, 0, 10, 1, 1, 0]
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: truncated)]) == nil)
        // one byte short of even that
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: Array(truncated.dropLast()))]) == nil)
    }

    /// A length field larger than the buffer terminates the walk instead of
    /// indexing past the end or spinning.
    @Test func anOverlongDeclaredLengthTerminates() {
        let data: [UInt8] = [255, 200, 0, 0, 10, 1, 1, 0, 2, 0, 0, 0]
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: data)]) == .recordStart)

        let noTrigger: [UInt8] = [255, 200, 0, 0, 4, 0, 1, 0, 9, 9, 9, 9]
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: noTrigger)]) == nil)
    }

    /// Commands are 32-bit aligned: a 6-byte command occupies 8 bytes of data
    /// after its header, so the next command starts at +12. Getting the padding
    /// wrong walks into the middle of the following command.
    @Test func commandsAreWalkedOnFourByteAlignment() {
        // lens command declaring length 5 (padded to 8), then transport record
        let data: [UInt8] = [255, 5, 0, 0, 0, 0, 1, 0, 7, 0, 0, 0]
            + transportCommand(mode: 2)
        #expect(VancParser.recTrigger(in: [AncillaryPacket(
            did: did, sdid: sdid, data: data)]) == .recordStart)
    }

    /// Only the camera-control SDID is parsed: tally (0x52) and closed captions
    /// share DID 0x51 / the same wire and must never move the recorder.
    @Test func otherSDIDsUnderTheSameDIDAreIgnored() {
        let payload = transportCommand(mode: 2)
        #expect(VancParser.recTrigger(in: [
            AncillaryPacket(did: did, sdid: VancParser.tallySDID, data: payload),
            AncillaryPacket(did: 0x61, sdid: 0x01, data: payload),
        ]) == nil)
    }

    /// A batch where the first camera-control packet carries nothing usable
    /// still has to reach the one that does.
    @Test func aLaterPacketInTheBatchIsStillParsed() {
        #expect(VancParser.recTrigger(in: [
            AncillaryPacket(did: did, sdid: sdid, data: [0, 0, 0, 0]),
            AncillaryPacket(did: did, sdid: sdid, data: transportCommand(mode: 2)),
        ]) == .recordStart)
    }

    /// The monitor aggregates packets by this key, so its format is the identity
    /// of a row: change it and a stream's counts split across two lines.
    @Test func packetStatKeyIsUppercaseHexDIDSlashSDID() {
        let stat = VancPacketStat(did: 0x51, sdid: 0x53, count: 3,
                                  lastLine: 9, lastDataHex: "FF 06")
        #expect(stat.key == "51/53")
        #expect(stat.id == stat.key)

        let low = VancPacketStat(did: 0x00, sdid: 0x0A, count: 1,
                                 lastLine: 0, lastDataHex: "")
        #expect(low.key == "00/0A")
    }
}
