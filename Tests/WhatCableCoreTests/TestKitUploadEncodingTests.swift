import Foundation
import Testing
@testable import WhatCableCore

@Suite("Test-kit upload encoding")
struct TestKitUploadEncodingTests {
    @Test("CRC-32 matches the standard check value")
    func crcCheckValue() {
        #expect(TestKitUploadEncoding.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("gzip framing: RFC 1952 header, and the trailer holds the CRC-32 and length")
    func framing() throws {
        let input = Data("hello, format 1".utf8)
        let gz = try TestKitUploadEncoding.gzip(input)
        #expect(Array(gz.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00])
        let trailer = Array(gz.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(crc == TestKitUploadEncoding.crc32(input))
        #expect(size == UInt32(input.count))
    }

    @Test("Python's gzip module decodes it back to the input", arguments: [0, 1, 4096, 1 << 20])
    func pythonRoundTrip(byteCount: Int) throws {
        // Ingest decodes with Python, so Python is the decoder that matters.
        // Mixed content: half repetitive JSON-like text, half pseudo-random bytes.
        var generator = SystemRandomNumberGenerator()
        var input = Data(String(repeating: "{\"t\":\"int\",\"bits\":32}", count: byteCount / 44 + 1).utf8.prefix(byteCount / 2))
        input.append(contentsOf: (0..<(byteCount - input.count)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whatcable-gzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("raw.bin")
        let encoded = dir.appendingPathComponent("encoded.txt")
        try input.write(to: raw)
        try TestKitUploadEncoding.gzipBase64(input).write(to: encoded, atomically: true, encoding: .utf8)

        let script = """
            import base64, gzip, sys
            raw = open(sys.argv[1], 'rb').read()
            back = gzip.decompress(base64.b64decode(open(sys.argv[2]).read()))
            sys.exit(0 if back == raw else 1)
            """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", script, raw.path, encoded.path]
        try python.run()
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
    }
}
