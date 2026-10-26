import Foundation
import Testing
@testable import WhatCable
import WhatCableCore

// These tests launch real subprocesses and include an intentional watchdog
// timeout. Serial execution keeps the timeout test from racing the two
// concurrent 31 MiB output fixtures on slower CI hosts.
@Suite("Test Kit probe output limit", .serialized)
struct TestKitRunnerOutputLimitTests {
    @Test("Output at the byte limit is preserved")
    @MainActor
    func outputAtLimitIsPreserved() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        #expect(result.output?.count == TestKitRunner.maxProbeOutputBytes)
        #expect(!result.didExceedOutputLimit)
    }

    @Test("Output over the byte limit is rejected")
    @MainActor
    func outputOverLimitIsRejected() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes + 1)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        let outputWasRejected = result.output == nil
        #expect(outputWasRejected)
        #expect(result.didExceedOutputLimit)
    }

    @Test("An unbounded child is terminated as soon as it exceeds the limit")
    @MainActor
    func unboundedChildIsTerminatedAtLimit() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            timeout: 5
        )

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == nil)
        #expect(result.didExceedOutputLimit)
        #expect(elapsed < .seconds(3))
    }

    @Test("A SIGTERM-ignoring child is force-killed after the grace period", .timeLimit(.minutes(1)))
    @MainActor
    func sigtermImmuneChildIsForceKilled() async throws {
        // trap '' TERM makes the shell ignore SIGTERM, and the ignored
        // disposition is inherited by every child it spawns, so only the
        // SIGKILL escalation ends this fixture early. It is deliberately
        // self-limiting (exits on its own after the sleep): if the
        // escalation regresses, the test must FAIL fast on the elapsed-time
        // assertion, not hang the suite on a child nothing can kill.
        // A whole 64 KiB read chunk over the cap, sized from the constant so
        // the fixture follows any change to it. Less than a whole chunk over
        // would not do: read(upToCount:) only hands back a short chunk at
        // EOF, which the sleeping shell holds off, so the overshoot would go
        // unseen until the watchdog. One `head` rather than a loop of `dd`
        // calls: a few hundred forks would eat into the elapsed-time budget.
        let fixture = try makeScript(contents: """
            #!/bin/sh
            trap '' TERM
            /usr/bin/head -c \(TestKitRunner.maxProbeOutputBytes + 64 * 1024) /dev/zero
            /bin/sleep 15
            """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 10)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == nil)
        #expect(result.didExceedOutputLimit)
        #expect(!result.didTimeout)
        // Cap is hit almost instantly, so the run should end at roughly the
        // 2s SIGKILL grace period, well before the 10s watchdog.
        #expect(elapsed < .seconds(8))
    }

    @Test("Small partial output from the watchdog path is preserved")
    @MainActor
    func timeoutPartialOutputIsPreserved() async throws {
        let fixture = try makeScript(contents: "#!/bin/sh\n/bin/echo partial\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == Data("partial\n".utf8))
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
        // The watchdog fires at 2s; returning near the fixture's 5s sleep
        // would mean a leftover writer kept the pipe open.
        #expect(elapsed < .seconds(4))
    }

    @Test("An incomplete UTF-8 sequence from the watchdog path is preserved byte for byte")
    @MainActor
    func timeoutIncompleteUTF8IsPreserved() async throws {
        // A lone UTF-8 lead byte. Output is never decoded as text now, so it
        // must come back as itself, not as U+FFFD.
        let fixture = try makeScript(contents: "#!/bin/sh\n/usr/bin/printf '\\303'\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == Data([0xC3]))
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
        #expect(elapsed < .seconds(4))
    }

    @Test("Oversized JSON request bodies are rejected")
    @MainActor
    func oversizedJSONBodyIsRejected() throws {
        let payload = ["output": String(repeating: "x", count: TestKitRunner.maxRequestBodyBytes)]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body == nil)
    }

    @Test("Small JSON request bodies are preserved")
    @MainActor
    func smallJSONBodyIsPreserved() throws {
        let payload = ["output": "diagnostic"]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body != nil)
    }

    @Test("A submit body carries the probe's raw bytes gzipped and base64-encoded, with the run ID")
    func submitPayloadEncodesRawBytes() throws {
        // 0xFF is never valid UTF-8, so any text decode on the upload path
        // would turn it into U+FFFD and this round trip would fail.
        let raw = Data("{\"record\":\"header\"}\n".utf8) + Data([0xFF, 0x00, 0xC3])

        let payload = try TestKitRunner.submitPayload(
            runID: "6f1c2a7e-0d4b-4c3a-9b1e-2f5d8a7c6b40",
            machineID: "machine",
            probeName: "50_registry_snapshot",
            output: raw,
            macosVersion: "26.0",
            chip: "Apple M4 Pro",
            model: "Mac16,11",
            timestamp: "2026-10-07T12:00:00Z"
        )

        #expect(payload["output_encoding"] as? String == "gzip+base64")
        #expect(payload["run_id"] as? String == "6f1c2a7e-0d4b-4c3a-9b1e-2f5d8a7c6b40")
        // Every field the worker already reads is still there, unchanged.
        #expect(payload["machine_id"] as? String == "machine")
        #expect(payload["probe_name"] as? String == "50_registry_snapshot")
        #expect(payload["macos_version"] as? String == "26.0")
        #expect(payload["chip"] as? String == "Apple M4 Pro")
        #expect(payload["model"] as? String == "Mac16,11")
        #expect(payload["timestamp"] as? String == "2026-10-07T12:00:00Z")

        // Undo the encoding independently of TestKitUploadEncoding: base64,
        // then drop gzip's 10-byte header and 8-byte trailer, leaving the raw
        // DEFLATE stream Foundation's .zlib inflates.
        let encoded = try #require(payload["output"] as? String)
        let gzip = try #require(Data(base64Encoded: encoded), "output is not base64")
        try #require(gzip.count > 18)
        let deflated = gzip.subdata(in: 10..<(gzip.count - 8))
        let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == raw)
    }

    @Test("The output cap is the snapshot's byte cap plus 1 MiB, and a request stays under the worker's 25 MiB")
    func outputCapFollowsTheSnapshotByteCap() throws {
        // 50_registry_snapshot starts no new record at or past BYTE_CAP, but
        // the record in hand and the footer still land after it, so the app
        // allows 1 MiB on top. The worker refuses bodies over one KV value
        // (25 MiB).
        let source = try String(
            contentsOf: probeSourcesDirectory.appendingPathComponent("50_registry_snapshot.c"),
            encoding: .utf8
        )
        let ns = source as NSString
        let pattern = try NSRegularExpression(pattern: #"#define BYTE_CAP \((\d+)ULL \* 1024 \* 1024\)"#)
        let match = try #require(
            pattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
            "no BYTE_CAP found in 50_registry_snapshot.c"
        )
        let byteCapMiB = try #require(Int(ns.substring(with: match.range(at: 1))))
        let mib = 1024 * 1024

        #expect(TestKitRunner.maxProbeOutputBytes == (byteCapMiB + 1) * mib)
        #expect(TestKitRunner.maxRequestBodyBytes <= 25 * mib)
    }

    @Test("A probe runs with the parent's environment plus WHATCABLE_APP_VERSION")
    @MainActor
    func probeSeesTheAppVersion() async throws {
        // HOME proves the parent's environment still reaches the probe, so
        // setting the version cannot quietly replace everything else.
        let fixture = try makeScript(
            contents: "#!/bin/sh\n/usr/bin/printf '%s|%s' \"$HOME\" \"$WHATCABLE_APP_VERSION\"\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        #expect(result.output == Data("\(home)|\(AppInfo.version)".utf8))
    }

    @Test("Every probe's byte cap stops below the app's output cap")
    @MainActor
    func probeBudgetsSitUnderTheOutputCap() throws {
        // A probe whose own byte cap reaches the app's cap has its whole
        // output discarded (see outputOverLimitIsRejected), not trimmed. A
        // format 1 probe writes a record only if it fits under its cap, so
        // only the footer line lands past it; keep at least 512 KiB clear
        // regardless. Every probe in the kit must
        // declare a cap: a source without one fails here.
        let probes = probeSourcesDirectory
        let sources = try FileManager.default.contentsOfDirectory(atPath: probes.path)
            .filter { $0.hasSuffix(".c") }
            .sorted()
        try #require(!sources.isEmpty, "no probe sources in probes/test-kit")
        let pattern = try NSRegularExpression(pattern: #"#define BYTE_CAP \((\d+)ULL \* 1024 \* 1024\)"#)
        for name in sources {
            let source = try String(contentsOf: probes.appendingPathComponent(name), encoding: .utf8)
            let ns = source as NSString
            let match = try #require(
                pattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
                "no BYTE_CAP found in \(name)"
            )
            let mib = try #require(Int(ns.substring(with: match.range(at: 1))))
            let headroom = 512 * 1024
            #expect(mib * 1024 * 1024 + headroom <= TestKitRunner.maxProbeOutputBytes,
                    "\(name) cap \(mib) MiB is too close to the app cap")
        }
    }

    private var probeSourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("probes/test-kit")
    }

    private func makeOutputFixture(byteCount: Int) throws -> URL {
        try makeScript(contents: "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c \(byteCount)\n")
    }

    private func makeScript(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatcable-test-kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("emit-output")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
