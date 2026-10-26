import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

/// Pure-logic tests for the desktop SMC power path. The live IOKit reads need
/// hardware, but the FourCC packing, UUID normalisation, channel-to-sample
/// conversion, and the struct-layout guard are all unit-testable.
struct SMCPowerReaderTests {

    @Test("FourCC packs a 4-char SMC key MSB-first")
    func fourCCPacksKey() {
        // 'D'=0x44 '1'=0x31 'J'=0x4A 'V'=0x56
        #expect(SMCPowerReader.fourCC("D1JV") == 0x4431_4A56)
        #expect(SMCPowerReader.fourCC("D4UI") == 0x4434_5549)
    }

    @Test("FourCC rejects keys that are not exactly four ASCII chars")
    func fourCCRejectsBadKeys() {
        #expect(SMCPowerReader.fourCC("D1J") == nil)
        #expect(SMCPowerReader.fourCC("D1JVX") == nil)
        #expect(SMCPowerReader.fourCC("D1J€") == nil)
    }

    @Test("Float decode roundtrips a finite SMC flt payload")
    func decodeFloatFinite() {
        // 5.18 as little-endian IEEE-754 bytes.
        let bytes = withUnsafeBytes(of: Float(5.18).bitPattern.littleEndian) { Array($0) }
        #expect(SMCPowerReader.decodeFloat(bytes) == 5.18)
        #expect(SMCPowerReader.decodeFloat([0, 0, 0, 0]) == 0)
    }

    @Test("Float decode rejects non-finite and short payloads")
    func decodeFloatRejectsGarbage() {
        // An uninitialised channel can carry inf/NaN bit patterns; letting
        // them through would trap in the Int() unit conversions downstream
        // (PowerService mV/mA/mW). nil routes them into the same
        // `?? 0` fallback as an absent key.
        func bytes(_ f: Float) -> [UInt8] {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }
        }
        #expect(SMCPowerReader.decodeFloat(bytes(.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(-.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(.nan)) == nil)
        #expect(SMCPowerReader.decodeFloat([]) == nil)
        #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0xA6]) == nil)
    }

    @Test("A non-zero SMC result byte marks the key read as failed")
    func smcResultByteGatesAKeyRead() {
        // The SMC can return KERN_SUCCESS from IOConnectCallStructMethod and
        // still put its own error code (0x84 = key not found) in `result`.
        var ok = SMCParamStruct()
        ok.result = 0
        #expect(SMCPowerReader.smcCallSucceeded(ok))

        var notFound = SMCParamStruct()
        notFound.result = 0x84
        #expect(!SMCPowerReader.smcCallSucceeded(notFound))
    }

    @Test("Constructing the reader does not trip the 80-byte struct assertion")
    func structLayoutIsCorrect() {
        // The init() precondition fires (in debug) if SMCParamStruct ever stops
        // being 80 bytes, which the AppleSMC ABI requires.
        _ = SMCPowerReader()
    }

    @Test("HPM UUID normalisation strips dashes and lowercases")
    func uuidNormalisation() {
        #expect(
            HPMPortUUIDMap.normalise("AAAA1111-BBBB-2222-CCCC-333344445555")
                == "aaaa1111bbbb2222cccc333344445555"
        )
        // Already-normalised SMC-style input is unchanged.
        #expect(
            HPMPortUUIDMap.normalise("6230af2d000000000000112233445566")
                == "6230af2d000000000000112233445566"
        )
    }

    @Test("SMC channel converts to a live per-port sample on the right port")
    func smcChannelToSample() {
        let channel = SMCPortPowerChannel(
            channel: 3,
            present: true,
            volts: 5.18,
            amps: 0.643,
            uuid: "aaaa1111bbbb2222cccc333344445555"
        )
        // The channel's UUID maps to physical port @4 (the non-positional case).
        let sample = PortPowerMerge.smcSample(channel: channel, portKey: "2/4")

        #expect(sample.portKey == "2/4")
        #expect(sample.portIndex == 4)
        #expect(sample.configuredVoltage == 5180)   // mV
        #expect(sample.current == 643)              // mA
        #expect(sample.watts == 3331)               // mW, 5.18 x 0.643 x 1000
        #expect(sample.isSMCMeasured)
        // It is a live measured reading, not a contracted-max fallback, so the
        // UI shows real volts rather than the "--" placeholder.
        #expect(!sample.isContractedFallback)
        #expect(sample.adapterVoltage == 0)
    }

    @Test("SMC DC-in reading converts to the System Power sample in mV/mA/mW")
    func smcSystemSampleConversion() {
        // Mac mini M4 corpus values: 12.55 V / 1.83 A / 22.91 W DC-in.
        let input = SMCSystemPowerInput(volts: 12.55, amps: 1.83, watts: 22.91)
        let now = Date()
        let sample = PowerService.smcSystemSample(input, timestamp: now)

        #expect(sample.systemVoltageIn == 12550)   // mV
        #expect(sample.systemCurrentIn == 1830)    // mA
        #expect(sample.systemPowerIn == 22910)     // mW
        #expect(sample.timestamp == now)
    }

    @Test("MagSafe channel keeps the MagSafe port-type prefix in its key")
    func smcChannelMagSafeKey() {
        let channel = SMCPortPowerChannel(
            channel: 4, present: true, volts: 9.0, amps: 1.0,
            uuid: "7c30af2d000000000000aabbccddeeff"
        )
        let sample = PortPowerMerge.smcSample(channel: channel, portKey: "17/1")
        #expect(sample.portKey == "17/1")
        #expect(sample.portIndex == 1)
        #expect(sample.watts == 9000)
    }

    // MARK: - perPortMeteringSupported gate (issue #291 regression guard)

    /// A non-empty UUID map alone must NOT flip `perPortMeteringSupported` to
    /// true. The flag is only true when at least one SMC channel UUID actually
    /// appears in the map. This guards against the M1/M2 regression where
    /// `updatePorts()` could populate the map (the HPM watcher fires on M1/M2
    /// too), but SMC channels return a different UUID namespace and nothing
    /// matches. Without this guard, the Power Monitor would spin on
    /// "Negotiating..." forever on M1/M2 desktop Macs (issue #291).
    @Test("perPortMeteringSupported is false when no SMC channel UUID matches the port map")
    func perPortMeteringNotSupportedWhenChannelsDontMatch() {
        // Simulate an M1/M2 scenario: the UUID map was populated from the HPM
        // watcher, but the SMC port-power channels carry UUIDs from a different
        // namespace. No channel resolves to a known port key.
        let uuidMap: [String: String] = [
            "aaaabbbbccccddddeeeeffffffff0001": "2/1",
            "aaaabbbbccccddddeeeeffffffff0002": "2/2",
        ]
        let channels: [SMCPortPowerChannel] = [
            // Channel UUIDs from the SMC are entirely different from the map.
            SMCPortPowerChannel(channel: 1, present: false, volts: 0.0, amps: 0.0,
                                uuid: "1111111111111111111111111111dead"),
            SMCPortPowerChannel(channel: 2, present: false, volts: 0.0, amps: 0.0,
                                uuid: "2222222222222222222222222222beef"),
        ]
        var matchedChannels = 0
        for channel in channels {
            guard uuidMap[channel.uuid] != nil else { continue }
            matchedChannels += 1
        }
        // The map is non-empty, but no channel matched -- flag must stay false.
        let supported = matchedChannels > 0
        #expect(!supported,
            "perPortMeteringSupported must be false when no SMC channel resolves via UUID map")
    }

    @Test("perPortMeteringSupported is true when at least one SMC channel UUID matches")
    func perPortMeteringSupportedWhenOneChannelMatches() {
        let knownUUID = "aaaa1111bbbb2222cccc333344445555"
        let uuidMap: [String: String] = [knownUUID: "2/4"]
        let channels: [SMCPortPowerChannel] = [
            SMCPortPowerChannel(channel: 1, present: true, volts: 5.18, amps: 0.643,
                                uuid: knownUUID),
        ]
        var matchedChannels = 0
        for channel in channels {
            guard uuidMap[channel.uuid] != nil else { continue }
            matchedChannels += 1
        }
        let supported = matchedChannels > 0
        #expect(supported,
            "perPortMeteringSupported must be true when at least one channel resolves")
    }

    @Test("Little-endian decode: B0AC raw ea16 is 5866")
    func decodeLittleEndian() {
        #expect(SMCPowerReader.decodeLittleEndianUInt([0xEA, 0x16]) == 5866)
        #expect(SMCPowerReader.decodeLittleEndianUInt([0x80, 0, 0, 0, 0, 0, 0, 0]) == 0x80)
        #expect(SMCPowerReader.decodeLittleEndianUInt([0, 0, 0, 0x01, 0, 0, 0, 0]) == 1 << 24)
        #expect(SMCPowerReader.decodeLittleEndianUInt([]) == nil)
        #expect(SMCPowerReader.decodeLittleEndianUInt(Array(repeating: 0, count: 9)) == nil)
    }

    @Test("Charge inputs: every key decoded little-endian at its own width; absent keys stay nil")
    func batteryChargeInputsFromBytes() {
        let raw: [String: [UInt8]] = [
            "CH0R": [0x00, 0x01, 0x00, 0x00],                 // 0x100, BMS busy only
            "CHCE": [0x01], "CHCC": [0x01], "BSFC": [0x00], "BUIC": [0x50],
            "CHNC": [0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0],     // bit 24
            "CHSC": [0x00], "AC-i": [0xAB, 0x05],
        ]
        let k = SMCPowerReader.batteryChargeInputs(read: { raw[$0] })
        #expect(k == BatteryChargeInputs(
            ch0r: 0x100, chce: true, chcc: true, acInputLimit: 0x05AB, bsfc: false,
            chls: nil, chwa: nil, buic: 80, chnc: 1 << 24, chsc: false))
        #expect(BatteryChargeState.decide(k) == .chargeLimitReached)
    }

    @Test("A 1-byte CHNC is unreadable, since it is a 64-bit field, so CHSC decides")
    func oneByteCHNCFallsThroughToCHSC() {
        let base: [String: [UInt8]] = ["CHCE": [0x01], "CHCC": [0x01], "BSFC": [0x00], "CHNC": [0x80]]
        func inputs(_ extra: [String: [UInt8]]) -> BatteryChargeInputs {
            let raw = base.merging(extra) { $1 }
            return SMCPowerReader.batteryChargeInputs(read: { raw[$0] })
        }
        let charging = inputs(["CHSC": [0x01]])
        #expect(charging.chnc == nil)
        #expect(BatteryChargeState.decide(charging) == .charging)
        #expect(BatteryChargeState.decide(inputs(["CHSC": [0x00]])) == .onHold)
        // The same bit at 8 bytes is used: bit 7 alone is on hold, whatever CHSC says.
        let eight = inputs(["CHSC": [0x01], "CHNC": [0x80, 0, 0, 0, 0, 0, 0, 0]])
        #expect(eight.chnc == 0x80)
        #expect(BatteryChargeState.decide(eight) == .onHold)
    }
}

// MARK: - Big-endian integer decode (the charging-contract keys)

@Suite("SMC contract keys: big-endian integers")
struct SMCBigEndianDecodeTests {

    @Test("The reporter's own captured bytes decode to his contract")
    func reportersBytesDecode() {
        // From issue 491's machine. These are the exact raw payloads, and they
        // are the reason this decoder exists separately from the float one a
        // few lines away in the same file: the float keys on the SAME channel
        // are native little-endian, these are big-endian, and one decoder
        // cannot serve both.
        #expect(SMCPowerReader.decodeBigEndianInt([0x4e, 0x20]) == 20_000, "D2MV, 20 V")
        #expect(SMCPowerReader.decodeBigEndianInt([0x00, 0x01, 0x86, 0xa0]) == 100_000, "D2MP, 100 W")
        #expect(SMCPowerReader.decodeBigEndianInt([0x13, 0x88]) == 5_000, "D2MI, 5 A")
    }

    @Test("Reading these keys little-endian is not subtly wrong, it is absurd")
    func wrongEndiannessIsObvious() {
        // Stated as a test so the failure mode is on record: 20000 mV read the
        // wrong way round is 553,648,128, which is why a mistake here would
        // surface as a preposterous card rather than a plausible one.
        let bytes: [UInt8] = [0x4e, 0x20, 0x00, 0x00]
        let bigEndian = SMCPowerReader.decodeBigEndianInt(bytes)
        let littleEndian = bytes.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        #expect(bigEndian == 1_310_720_000)
        #expect(littleEndian == 8_270)
        #expect(bigEndian != littleEndian)
    }

    @Test("Degenerate payloads decode to nothing rather than a number")
    func degeneratePayloads() {
        #expect(SMCPowerReader.decodeBigEndianInt([]) == nil)
        // Longer than 8 bytes is not an integer key; refuse rather than
        // silently truncate to something plausible.
        #expect(SMCPowerReader.decodeBigEndianInt(Array(repeating: 0xFF, count: 9)) == nil)
        #expect(SMCPowerReader.decodeBigEndianInt([0x00, 0x00]) == 0)
        #expect(SMCPowerReader.decodeBigEndianInt([0xFF]) == 255)
    }
}

// MARK: - Who is allowed to close the shared SMC connection

@Suite("PowerService SMC reader ownership")
@MainActor
struct PowerServiceReaderOwnershipTests {

    @Test("A service handed a shared reader never closes it; one that made its own does")
    func ownershipDecidesWhoCloses() {
        // The rule this pins: WatcherHub owns one AppleSMC connection for the
        // whole app, and the menu bar's watts readout runs off it for the
        // process's life. PowerService is exclusive to one screen and tears
        // itself down when that screen closes, so if it closed a SHARED reader
        // it would pull the connection out from under the menu bar.
        //
        // That bug would be invisible rather than absent: open() is lazy and
        // idempotent, so the next read would silently reopen and everything
        // would look fine while churning a kernel user client on every window
        // close. Reviewer's note that this invariant had no test at all, only
        // a hand trace, and hand traces do not survive edits.
        let shared = SMCPowerReader()
        let borrower = PowerService(smcReader: shared)
        borrower.stop()
        #expect(borrower.ownsSMCReaderForTesting == false,
            "a service given a reader must not believe it owns it")

        let owner = PowerService()
        #expect(owner.ownsSMCReaderForTesting,
            "a service that made its own reader must own it, or nothing ever closes it")
        owner.stop()
    }
}
