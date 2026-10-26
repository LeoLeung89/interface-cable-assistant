import Foundation
import Testing
@testable import WhatCableCore

@Suite("Cable report sync script")
struct CableReportSyncTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Sync script labels match the CableSpeed report source of truth")
    func syncScriptLabelsMatchReportLabels() throws {
        let sourceURL = repoRoot().appendingPathComponent("scripts/sync-cable-reports.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*(\d+):\s*"([^"]*)",\s*$"#)
        var labels: [Int: String] = [:]
        let range = NSRange(source.startIndex..., in: source)

        for match in regex.matches(in: source, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source),
                  let key = Int(source[keyRange]) else { continue }
            labels[key] = String(source[valueRange])
        }

        for rawValue in 0...4 {
            let speed = try #require(PDVDO.CableSpeed(rawValue: rawValue))
            let scriptLabel = try #require(labels[rawValue])
            #expect(scriptLabel == speed.reportLabel)
        }
    }

    @Test("Raw Cable VDO speed derivation and fallbacks")
    func rawCableVDOSpeedDerivationAndFallbacks() throws {
        let process = Process()
        process.currentDirectoryURL = repoRoot()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "scripts/sync-cable-reports.swift", "--test-speed"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let outputData = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: output))
        #expect(output.contains("Cable report speed self-tests passed"))
    }
}
