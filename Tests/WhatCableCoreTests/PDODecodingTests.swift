import Testing
@testable import WhatCableCore

@Suite("PDO Decoding")
struct PDODecodingTests {
    @Test("Fixed supply: 5V 3A")
    func fixedSupply5V3A() {
        // bits 31:30 = 00 (fixed), bits 19:10 = 100 (100 * 50mV = 5000mV), bits 9:0 = 300 (300 * 10mA = 3000mA)
        let raw: UInt32 = (100 << 10) | 300
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .fixed(voltage: 5000, maxCurrent: 3000))
    }

    @Test("Fixed supply: 20V 5A")
    func fixedSupply20V5A() {
        let raw: UInt32 = (400 << 10) | 500
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .fixed(voltage: 20000, maxCurrent: 5000))
    }

    @Test("Fixed supply: 9V 3A")
    func fixedSupply9V3A() {
        let raw: UInt32 = (180 << 10) | 300
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .fixed(voltage: 9000, maxCurrent: 3000))
    }

    @Test("Battery supply: min voltage, max voltage, and max power (Table 6.11)")
    func batterySupply() {
        // bits 31:30 = 01 (battery)
        // bits 29:20 = 400 (400 * 50mV = 20000mV max)
        // bits 19:10 = 100 (100 * 50mV = 5000mV min)
        // bits 9:0   = 60  (60 * 250mW = 15000mW)
        let raw: UInt32 = (1 << 30) | (400 << 20) | (100 << 10) | 60
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .battery(minVoltage: 5000, maxVoltage: 20000, maxPower: 15000))
    }

    @Test("Variable supply: min voltage, max voltage, and max current (Table 6.12)")
    func variableSupply() {
        // bits 31:30 = 10 (variable)
        // bits 29:20 = 400 (400 * 50mV = 20000mV max)
        // bits 19:10 = 100 (100 * 50mV = 5000mV min)
        // bits 9:0   = 300 (300 * 10mA = 3000mA)
        let raw: UInt32 = (2 << 30) | (400 << 20) | (100 << 10) | 300
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .variable(minVoltage: 5000, maxVoltage: 20000, maxCurrent: 3000))
    }

    @Test("PPS APDO: 3.3-21V 5A (Table 6.13, subtype bits 29:28 = 00)")
    func apdoPPS() {
        // bits 31:30 = 11 (APDO), bits 29:28 = 00 (PPS)
        // bits 24:17 = 210 (210 * 100mV = 21000mV max)
        // bits 15:8  = 33  (33 * 100mV = 3300mV min)
        // bits 6:0   = 100 (100 * 50mA = 5000mA)
        let raw: UInt32 = (3 << 30) | (0 << 28) | (210 << 17) | (33 << 8) | 100
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .pps(minVoltage: 3300, maxVoltage: 21000, maxCurrent: 5000))
    }

    @Test("EPR AVS APDO: 15-48V 140W (Table 6.16, subtype bits 29:28 = 01)")
    func apdoEPRAvs() {
        // bits 31:30 = 11 (APDO), bits 29:28 = 01 (EPR AVS)
        // bits 25:17 = 480 (480 * 100mV = 48000mV max); mask = 0x1FF = 9 bits
        // bits 15:8  = 150 (150 * 100mV = 15000mV min)
        // bits 7:0   = 140 (140 * 1W = 140W = 140000mW)
        let raw: UInt32 = (3 << 30) | (1 << 28) | (480 << 17) | (150 << 8) | 140
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .eprAvs(minVoltage: 15000, maxVoltage: 48000, pdp: 140000))
    }

    @Test("SPR AVS APDO: 3A at 15V, 3A at 20V (Table 6.15, subtype bits 29:28 = 10)")
    func apdoSPRAvs() {
        // bits 31:30 = 11 (APDO), bits 29:28 = 10 (SPR AVS)
        // bits 19:10 = 300 (300 * 10mA = 3000mA at 15V)
        // bits 9:0   = 300 (300 * 10mA = 3000mA at 20V)
        let raw: UInt32 = (3 << 30) | (2 << 28) | (300 << 10) | 300
        let pdo = PDO.decode(rawValue: raw)
        #expect(pdo == .sprAvs(maxCurrent15V: 3000, maxCurrent20V: 3000))
    }

    @Test("Negative ioreg value (unsigned overflow) decodes correctly")
    func negativeIoregOverflow() {
        // ioreg sometimes reports negative values for unsigned 32-bit PDOs.
        // Simulates masking a negative Int with 0xFFFFFFFF before decoding.
        let negative: Int = -1073741524
        let masked = UInt32(bitPattern: Int32(truncatingIfNeeded: negative))
        let pdo = PDO.decode(rawValue: masked)
        // Type bits 31:30 = 0b11 = APDO, remaining bits decode per APDO subtype layout
        switch pdo {
        case .pps, .eprAvs, .sprAvs:
            break // passes: correctly identified as an APDO variant
        default:
            Issue.record("Expected an APDO variant for overflow value, got \(pdo)")
        }
    }
}
