import Foundation

/// gzip and base64 for test-kit uploads.
///
/// A format 1 snapshot is 9 to 17 MB of JSON Lines; gzipped and base64-encoded
/// it is under 1 MB (measured 2026-10-07: 14,178,992 bytes became 970,356).
/// The worker stores the encoded string as received and never decodes it, and
/// ingest decodes it with Python's `gzip` module, so the framing is plain
/// RFC 1952: a 10-byte header, Foundation's raw DEFLATE (RFC 1951), then the
/// CRC-32 and length of the input.
public enum TestKitUploadEncoding {
    /// The `output_encoding` value sent with an encoded `output`.
    public static let name = "gzip+base64"

    public static func gzipBase64(_ data: Data) throws -> String {
        try gzip(data).base64EncodedString()
    }

    public static func gzip(_ data: Data) throws -> Data {
        // Foundation's .zlib is raw DEFLATE with no zlib header or checksum,
        // which is exactly what goes between gzip's header and trailer.
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        // Magic, CM = 8 (deflate), no flags, no modification time, no extra
        // flags, OS = 255 (unknown).
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.reserveCapacity(deflated.count + 18)
        out.append(deflated)
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    /// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), as gzip uses.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}
