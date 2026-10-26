import AppKit
import CryptoKit
import Foundation
import os.log
import WhatCableCore
import WhatCableDarwinBackend

@MainActor
final class TestKitRunner: ObservableObject {
    static let shared = TestKitRunner()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "test-kit")
    private static let apiURL = "https://whatcable-test-kit.darrylmorley-uk.workers.dev"
    // Bound both the retained child output and the encoded network copy. The
    // output cap is 50_registry_snapshot's own BYTE_CAP (30 MiB) plus 1 MiB
    // for the record in hand and the footer it still writes past that; more
    // than this is rejected whole, never truncated. Output goes up gzipped
    // and base64-encoded, which shrinks it (a 14 MB snapshot encodes to under
    // 1 MB), so the request cap can sit below the output cap: 24 MiB, under
    // the 25 MiB the worker refuses (one Workers KV value).
    // TestKitRunnerOutputLimitTests pins both against those sources.
    nonisolated static let maxProbeOutputBytes = 31 * 1024 * 1024
    nonisolated static let maxRequestBodyBytes = 24 * 1024 * 1024
    private nonisolated static let probeReadChunkBytes = 64 * 1024

    enum State: Equatable {
        case idle
        case running(probe: String, current: Int, total: Int)
        // `noOutputProbes` carries names (no output content) for an optional
        // subtle tooltip in the settings UI; `noOutput` is the count for the
        // completion label. See `runAllProbes()` for how a probe lands here
        // vs in `passed`/`failed`.
        case done(passed: Int, failed: Int, noOutput: Int, noOutputProbes: [String])
        case error(String)
    }

    @Published private(set) var state: State = .idle

    static let probeNames: [String] = [
        "50_registry_snapshot",
        "51_driver_access",
        "52_usb_bos",
        "53_smc_keys",
        "54_power_sources",
        "55_hub_ports",
    ]

    /// Probes sampled twice per kit run: once in their place in `probeNames`
    /// and again at the very end, after every other probe has finished. The
    /// registry snapshot is the only one. It records the whole registry, so
    /// comparing its two captures shows any state that drifted during the
    /// run (port, power, battery, Thunderbolt). It replaces the old repeats
    /// (31, 32, 29), which each sampled one slice of that. Order here is the
    /// order the end-of-run captures execute in.
    static let repeatProbes: [String] = [
        "50_registry_snapshot",
    ]

    /// One entry in the execution plan: which probe binary to run, and what
    /// name to submit the result under. For a normal (first-position) run
    /// these are the same string. For an end-of-run repeat they differ: the
    /// binary is unchanged, but the submission name gets an `_end` suffix so
    /// it lands under a distinct KV key (`{machine_hash}:{probe_name}`)
    /// instead of overwriting the first capture.
    struct ProbeRun: Equatable {
        let binaryName: String
        let submissionName: String
    }

    /// Builds the full ordered list of what this run actually executes and
    /// submits: every probe once in its normal position, then `repeatProbes`
    /// again at the end. Pure function (no I/O) so it can be unit tested
    /// without launching real probe binaries. Parameters default to the real
    /// lists; tests pass their own to exercise edge cases (e.g. a repeat name
    /// not present in `probeNames`).
    nonisolated static func executionPlan(
        probeNames: [String] = probeNames,
        repeatProbes: [String] = repeatProbes
    ) -> [ProbeRun] {
        var plan = probeNames.map { ProbeRun(binaryName: $0, submissionName: $0) }
        plan += repeatProbes.map { ProbeRun(binaryName: $0, submissionName: "\($0)_end") }
        return plan
    }

    private var runTask: Task<Void, Never>?

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func run() {
        guard Bundle.main.object(forInfoDictionaryKey: "WhatCableLabBuild") as? Bool != true else {
            let alert = NSAlert()
            alert.messageText = "此独立版本不向原项目上传诊断数据"
            alert.informativeText = "请通过本项目 GitHub Issues 反馈，并先检查日志中的设备信息。"
            alert.runModal()
            return
        }
        guard !isRunning else { return }

        runTask = Task {
            await runAllProbes()
            runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            state = .idle
        }
    }

    private func runAllProbes() async {
        let machineID = await Task.detached { Self.machineID() }.value
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        let macosVersion = ver.patchVersion > 0
            ? "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
            : "\(ver.majorVersion).\(ver.minorVersion)"
        let chip = Self.chipName()
        let model = DarwinSystemInfo.fetchMacModel()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // One ID for the whole run, sent with every /submit and with
        // /complete, so the worker can tell which captures belong together
        // (the two registry snapshot captures especially).
        let runID = UUID().uuidString.lowercased()

        guard let probesDir = Self.probesDirectory() else {
            state = .error("Probe binaries not found in app bundle")
            Self.log.error("Probe binaries directory not found")
            return
        }

        let plan = Self.executionPlan()
        let total = plan.count
        var passed = 0
        var failed = 0
        var noOutputProbes: [String] = []

        for (index, run) in plan.enumerated() {
            guard !Task.isCancelled else {
                state = .idle
                return
            }

            let probeName = run.submissionName
            state = .running(probe: probeName, current: index + 1, total: total)

            let binaryURL = probesDir.appendingPathComponent(run.binaryName)
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                Self.log.warning("Probe binary not found: \(run.binaryName)")
                noOutputProbes.append(probeName)
                continue
            }

            let result = await runProbe(at: binaryURL)

            // A cancel() can land while runProbe() is awaiting (the probe
            // itself keeps running to completion, since runProbe isn't
            // cancellation-aware; see its doc comment). Without this check
            // the probe that was in flight when cancel() was pressed would
            // still get submitted after the user asked to stop. Checking
            // here, before the accounting/submission below, means a
            // cancelled run submits nothing more from this point on.
            guard !Task.isCancelled else {
                state = .idle
                return
            }

            guard !result.didExceedOutputLimit else {
                Self.log.warning(
                    "Probe \(probeName) exceeded the \(Self.maxProbeOutputBytes)-byte output limit; discarding output"
                )
                noOutputProbes.append(probeName)
                continue
            }

            // Accounting decision (audit finding: crashes/empty-output/missing
            // binaries were silently uncounted). A probe lands in the new
            // no-output bucket, and its output (if any) is discarded, unless
            // it either exited cleanly (status 0, no signal) or was killed by
            // our own 30s watchdog below (`result.didTimeout`, an explicit
            // flag, not inferred from the exit signal, since an external
            // SIGTERM would look identical to our own). The watchdog case is
            // deliberately still treated as good data: when a probe is killed
            // for running long we'd still rather submit whatever it had
            // already written than throw it away, so it counts as
            // passed/failed same as a clean run, and only a log line notes
            // the timeout (not the no-output array, since it did produce
            // something and did get submitted). Any other nonzero exit or
            // signal (a genuine crash) is NOT trusted even if the pipe
            // carries partial bytes, since an unsupervised crash's output
            // isn't known to be well-formed; it goes to noOutputProbes and
            // nothing is submitted for it. Note the over-limit guard above
            // runs first and wins: a probe that both timed out and exceeded
            // the output cap is rejected, not submitted.
            let cleanExit = result.terminationReason == .exit && result.exitStatus == 0
            guard let output = result.output, !output.isEmpty, cleanExit || result.didTimeout else {
                Self.log.warning("Probe \(probeName) produced no usable output (exit \(result.exitStatus), reason \(String(describing: result.terminationReason)))")
                noOutputProbes.append(probeName)
                continue
            }

            if result.didTimeout {
                Self.log.info("Probe \(probeName) hit the 30s watchdog but produced output; submitting partial data")
            }

            // Built on the main actor: gzip and base64 of 14 MB of JSON Lines
            // took 70 ms in a release build (measured 2026-10-07), short
            // enough not to stall the settings UI, and only the two snapshot
            // captures are that big.
            let payload: [String: Any]
            do {
                payload = try Self.submitPayload(
                    runID: runID,
                    machineID: machineID,
                    probeName: probeName,
                    output: output,
                    macosVersion: macosVersion,
                    chip: chip,
                    model: model,
                    timestamp: timestamp
                )
            } catch {
                // Nothing can be sent without the encoding, so the probe
                // counts as producing no output rather than as a failed
                // submission.
                Self.log.error("Probe \(probeName) output could not be encoded: \(error.localizedDescription)")
                noOutputProbes.append(probeName)
                continue
            }

            let ok = await postJSON(to: "\(Self.apiURL)/submit", payload: payload)

            if ok {
                passed += 1
            } else {
                failed += 1
            }
        }

        // Without this, a cancel() that lands right after the loop's last
        // iteration (e.g. during the very last probe, including a repeat
        // run) would still fall through to /complete and .done, reporting a
        // finished run the user asked to stop.
        guard !Task.isCancelled else {
            state = .idle
            return
        }

        await submitComplete(
            runID: runID,
            machineID: machineID,
            macosVersion: macosVersion,
            chip: chip,
            model: model,
            passed: passed,
            failed: failed,
            total: total,
            noOutputProbes: noOutputProbes
        )

        state = .done(passed: passed, failed: failed, noOutput: noOutputProbes.count, noOutputProbes: noOutputProbes)
        Self.log.info("Test kit complete: \(passed) passed, \(failed) failed, \(noOutputProbes.count) no output\(noOutputProbes.isEmpty ? "" : ": \(noOutputProbes.joined(separator: ", "))")")

        AppSettings.shared.testKitLastRunVersion = AppInfo.version
    }

    /// Everything `runProbe` learns about how the probe process ended, so the
    /// caller can distinguish "ran cleanly", "we killed it on the 30s
    /// watchdog", and "it crashed/exited nonzero on its own" instead of just
    /// getting an output string. `didTimeout` is the source of truth for the
    /// watchdog case: `Process.terminate()` sends SIGTERM, but an external
    /// SIGTERM (someone else killing the probe) produces the exact same
    /// `terminationReason`/`terminationStatus` pair, so that pair alone can't
    /// distinguish "our watchdog" from "somebody else's kill" (raw signal 15
    /// is still worth knowing as a sanity check when reading logs, but it is
    /// not what this code branches on). `output` is the probe's bytes exactly
    /// as written, never decoded as text: they go up gzipped, so a byte that
    /// is not valid UTF-8 reaches the corpus intact.
    struct ProbeRunResult {
        let output: Data?
        let exitStatus: Int32
        let terminationReason: Process.TerminationReason
        let didTimeout: Bool
        let didExceedOutputLimit: Bool
    }

    /// How long a probe gets to honour SIGTERM before it is force-killed.
    private nonisolated static let terminateGraceSeconds: TimeInterval = 2

    /// SIGTERM first, then SIGKILL after a short grace period if the probe
    /// is still alive. `terminate()` alone is not enough of a guarantee: a
    /// child that ignores SIGTERM (or a forked descendant holding the pipe's
    /// write end) would leave the drain loop blocked on read() and
    /// `runAllProbes` stuck on this probe forever. SIGKILL cannot be caught
    /// or ignored. The kill targets the process group (Process makes the
    /// child its own group leader, which is why `terminate()` is documented
    /// as signalling subtasks too), falling back to the single pid if the
    /// group signal fails. The `isRunning` check just before the kill keeps
    /// the pid-reuse window (probe exits, pid recycled, we signal a
    /// stranger) as small as the platform allows; it cannot be closed
    /// entirely from userspace.
    private nonisolated static func terminateWithEscalation(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + terminateGraceSeconds) {
            guard process.isRunning else { return }
            if kill(-pid, SIGKILL) != 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Cross-queue flag: the timer fires on its own queue (`.global()`) and
    /// sets this *before* calling `process.terminate()`; the probe-running
    /// queue reads it after `process.waitUntilExit()` returns. A plain `var`
    /// captured by both closures would be a data race, so this uses the same
    /// NSLock-guarded-box pattern already used elsewhere in the app (e.g.
    /// `DashboardApp.swift`'s state boxes) rather than inferring the answer
    /// from the exit signal.
    private final class TimeoutMarker: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func markFired() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    /// Runs one probe binary to completion. Not cancellation-aware: a
    /// `Task.cancel()` on the caller does not terminate the child process
    /// early, it just stops being awaited once this returns. Making this
    /// method itself react to cancellation (terminating the in-flight probe
    /// early) is a bigger change with its own risks (killing a probe mid
    /// write, an escalation race with the existing timeout watchdog) and is
    /// deliberately out of scope here; callers that care about cancellation
    /// check `Task.isCancelled` after this returns instead.
    func runProbe(at binaryURL: URL, timeout: TimeInterval = 30) async -> ProbeRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = binaryURL
                // Setting `environment` replaces the inherited one, so start
                // from the parent's. Format 1 probes write the version into
                // their header line (probes/test-kit/probe_json.h).
                process.environment = ProcessInfo.processInfo.environment
                    .merging(["WHATCABLE_APP_VERSION": AppInfo.version]) { $1 }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    Self.log.error("Failed to launch probe: \(error.localizedDescription)")
                    continuation.resume(returning: ProbeRunResult(
                        output: nil,
                        exitStatus: -1,
                        terminationReason: .exit,
                        didTimeout: false,
                        didExceedOutputLimit: false
                    ))
                    return
                }

                let timeoutMarker = TimeoutMarker()

                // Timer is created only after process.run() succeeds, so the
                // catch path above cannot leak a live timer source.
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning {
                        // Set before terminate() so a read after
                        // waitUntilExit() always observes it once this
                        // handler has run at all.
                        timeoutMarker.markFired()
                        Self.terminateWithEscalation(process)
                    }
                }
                timer.resume()
                defer { timer.cancel() }

                // Drain the pipe while the probe runs; reading after waitUntilExit
                // deadlocks once output exceeds the pipe buffer. Retain at most
                // maxProbeOutputBytes, but keep draining after the limit so a
                // child already exiting cannot block on a full pipe. Oversized
                // output is rejected in full rather than submitted truncated.
                var data = Data()
                var didExceedOutputLimit = false
                var didFailReading = false
                do {
                    // Each read gets its own autorelease pool: FileHandle
                    // parks chunk buffers in the enclosing pool, which for
                    // this long-running block only drains when the loop ends,
                    // so a sustained drain would accumulate every chunk ever
                    // read (observed at gigabytes). Draining per chunk keeps
                    // the loop at one chunk of transient memory.
                    while let chunk = try autoreleasepool(invoking: {
                        try pipe.fileHandleForReading.read(upToCount: Self.probeReadChunkBytes)
                    }), !chunk.isEmpty {
                        guard !didExceedOutputLimit else { continue }

                        let remainingCapacity = Self.maxProbeOutputBytes - data.count
                        guard chunk.count <= remainingCapacity else {
                            didExceedOutputLimit = true
                            Self.terminateWithEscalation(process)
                            continue
                        }
                        data.append(chunk)
                    }
                } catch {
                    didFailReading = true
                    Self.log.error("Failed to read probe output: \(error.localizedDescription)")
                    Self.terminateWithEscalation(process)
                }
                process.waitUntilExit()
                continuation.resume(returning: ProbeRunResult(
                    output: didExceedOutputLimit || didFailReading ? nil : data,
                    exitStatus: process.terminationStatus,
                    terminationReason: process.terminationReason,
                    didTimeout: timeoutMarker.didFire,
                    didExceedOutputLimit: didExceedOutputLimit
                ))
            }
        }
    }

    /// The /submit body for one probe capture. `output` is the probe's raw
    /// bytes, sent gzipped and base64-encoded with `output_encoding` naming
    /// that, so nothing is lost to text decoding and a snapshot fits the
    /// request cap. `output_encoding` and `run_id` are new; every other field
    /// is as before. Throws only if the encoding fails. Pure (no I/O), so
    /// tests call it directly.
    nonisolated static func submitPayload(
        runID: String,
        machineID: String,
        probeName: String,
        output: Data,
        macosVersion: String,
        chip: String,
        model: String,
        timestamp: String
    ) throws -> [String: Any] {
        [
            "run_id": runID,
            "machine_id": machineID,
            "probe_name": probeName,
            "output": try TestKitUploadEncoding.gzipBase64(output),
            "output_encoding": TestKitUploadEncoding.name,
            "macos_version": macosVersion,
            "chip": chip,
            "model": model,
            "timestamp": timestamp,
        ]
    }

    private func submitComplete(
        runID: String,
        machineID: String,
        macosVersion: String,
        chip: String,
        model: String,
        passed: Int,
        failed: Int,
        total: Int,
        noOutputProbes: [String]
    ) async {
        var payload: [String: Any] = [
            "run_id": runID,
            "machine_id": machineID,
            "macos_version": macosVersion,
            "chip": chip,
            "model": model,
            "passed": passed,
            "failed": failed,
            "total": total,
            "no_output": noOutputProbes.count,
        ]
        if !noOutputProbes.isEmpty {
            payload["no_output_probes"] = noOutputProbes
        }

        _ = await postJSON(to: "\(Self.apiURL)/complete", payload: payload)
    }

    private func postJSON(to urlString: String, payload: [String: Any]) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            guard let body = try Self.boundedJSONBody(payload) else {
                Self.log.warning("Refusing POST to \(urlString): JSON body exceeds \(Self.maxRequestBodyBytes) bytes")
                return false
            }
            request.httpBody = body
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            Self.log.error("POST to \(urlString) failed: \(error.localizedDescription)")
            return false
        }
    }

    static func boundedJSONBody(_ payload: [String: Any]) throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: payload)
        return body.count <= maxRequestBodyBytes ? body : nil
    }

    static func probesDirectory() -> URL? {
        let fm = FileManager.default

        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("probes"),
           fm.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let contentsDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallback = contentsDir.appendingPathComponent("Resources/probes")
        if fm.fileExists(atPath: fallback.path) {
            return fallback
        }

        return nil
    }

    nonisolated static func machineID() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-d2", "-c", "IOPlatformExpertDevice"]
        process.standardOutput = pipe
        try? process.run()
        // Drain the pipe while the probe runs; reading after waitUntilExit
        // deadlocks once output exceeds the 64KB pipe buffer. ioreg output is
        // small so this never triggered here, but keep the ordering consistent.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        var uuid = "unknown"
        for line in output.components(separatedBy: "\n") {
            if line.contains("IOPlatformUUID") {
                let parts = line.components(separatedBy: "\"")
                if parts.count >= 4 {
                    uuid = parts[3]
                }
                break
            }
        }

        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func chipName() -> String {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var result = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &result, &size, nil, 0)
        return String(cString: result)
    }
}
