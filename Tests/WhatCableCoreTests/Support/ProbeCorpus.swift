import Foundation

/// Shared helpers for corpus-backed tests that replay customer probe files.
///
/// Probes live under `research/customer-probes/` in the repo root. Git tracks
/// only a subset (01_walk_pd_tree.json, inspection.md, and the distillations).
/// Probe files needed by a specific test suite are committed as test fixtures
/// via `git add -f`.
///
/// Usage pattern:
/// ```swift
/// let folders = ProbeCorpus.allFolders()
/// for folder in folders {
///     guard let text = ProbeCorpus.loadText(folder: folder, probe: "17_deep_property_dump")
///     else { continue }
///     let blocks = ProbeCorpus.parseDashBlocks(text: text, classPrefix: "IOPortFeaturePowerSource")
/// }
/// ```
public enum ProbeCorpus {

    // MARK: - Corpus root

    /// Absolute path to `research/customer-probes/` resolved via the test
    /// file's compile-time path so it works regardless of working directory.
    public static let root: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support/
            .deletingLastPathComponent()   // WhatCableCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    // MARK: - Folder enumeration

    /// All subdirectories under the corpus root, sorted alphabetically.
    /// Returns an empty array if the root does not exist (e.g. a fresh clone
    /// before raw probes are fetched from KV).
    public static func allFolders() -> [String] {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: root.path)
        else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = root.appendingPathComponent(entry).path
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return isDir.boolValue
        }.sorted()
    }

    // MARK: - JSON probe loader

    /// Load the `"output"` text string from a numbered probe JSON file.
    ///
    /// - Parameters:
    ///   - folder: The machine folder name (e.g. `"m1pro_macos26.5"`).
    ///   - probe: The probe filename stem without extension
    ///     (e.g. `"17_deep_property_dump"`).
    /// - Returns: The `output` text, or `nil` if the file is absent or
    ///   cannot be parsed. Callers should skip the folder silently when nil.
    public static func loadText(folder: String, probe: String) -> String? {
        let url = root
            .appendingPathComponent(folder)
            .appendingPathComponent("\(probe).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["output"] as? String
        else { return nil }
        return text
    }

    // MARK: - Block splitters

    /// Parse `--- ClassName[N] ---` style blocks from a probe text, returning
    /// the properties of each block as a `[String: Any]` dictionary.
    ///
    /// This format appears in the "All IOPort* services" flat section of
    /// probe 17 (`IOPortFeaturePowerSource`, `IOPortTransportState*`, etc.).
    ///
    /// - Parameters:
    ///   - text: The full probe output string.
    ///   - classPrefix: The class name to match, e.g. `"IOPortFeaturePowerSource"`.
    /// - Returns: One dict per matched block, in document order.
    public static func parseDashBlocks(text: String, classPrefix: String) -> [[String: Any]] {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: classPrefix)
        guard let regex = try? NSRegularExpression(
            pattern: "--- \(escapedPrefix)\\[\\d+\\] ---")
        else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text))

        var blocks: [[String: Any]] = []
        for (i, match) in matches.enumerated() {
            let bodyStart = match.range.upperBound
            let bodyEnd = i + 1 < matches.count
                ? matches[i + 1].range.lowerBound
                : nsText.length
            var body = nsText.substring(
                with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
            for sep in ["\n---", "\n==="] {
                if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
            }
            blocks.append(parseProperties(body: body, indent: "  "))
        }
        return blocks
    }

    /// Parse `=== ClassName ===` style blocks from a probe text.
    ///
    /// This format appears in the HPM deep-dive section of probe 17
    /// (`IOPortFeaturePowerSource`, `IOPortTransportStateCIO`, etc.).
    ///
    /// - Parameters:
    ///   - text: The full probe output string.
    ///   - className: The exact class name to match.
    /// - Returns: One dict per matched block, in document order.
    public static func parseEqualsBlocks(text: String, className: String) -> [[String: Any]] {
        let header = "=== \(className) ==="
        var blocks: [[String: Any]] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: header, range: searchFrom..<text.endIndex) {
            let bodyStart = range.upperBound
            let rest = String(text[bodyStart...])
            let body: String
            if let nextSection = rest.range(of: "\n=== ") ?? rest.range(of: "\n--- ") {
                body = String(rest[..<nextSection.lowerBound])
            } else {
                body = String(rest.prefix(2000))
            }
            blocks.append(parseProperties(body: body, indent: "      "))
            searchFrom = range.upperBound
        }
        return blocks
    }

    // MARK: - Property parsers

    /// Parse `KEY: VALUE` lines at a given indentation level into a dict.
    ///
    /// Value forms handled:
    /// - `N (0xHEX)` -> stored as `NSNumber(Int)`
    /// - `"quoted string"` -> stored as `String`
    /// - `true` / `false` -> stored as `NSNumber(Bool)`
    /// - Anything else is skipped (sub-dicts, binary data, etc.).
    public static func parseProperties(body: String, indent: String) -> [String: Any] {
        var props: [String: Any] = [:]
        let deeper = indent + " "
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard s.hasPrefix(indent), !s.hasPrefix(deeper) else { continue }
            let stripped = String(s.dropFirst(indent.count))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])

            if valStr == "true" {
                props[key] = NSNumber(value: true)
            } else if valStr == "false" {
                props[key] = NSNumber(value: false)
            } else if valStr.hasPrefix("\""), valStr.hasSuffix("\""), valStr.count >= 2 {
                props[key] = String(valStr.dropFirst().dropLast())
            } else if let m = matchInt(valStr) {
                props[key] = NSNumber(value: m)
            }
        }
        return props
    }

    /// Parse `KEY = VALUE` lines (probe-01 format, 4-space indent) into a dict.
    ///
    /// Probe 01 uses `    KEY = VALUE` indentation while probe 17 uses `KEY: VALUE`.
    /// This parser handles the probe-01 style.
    public static func parseEqualProperties(body: String, indent: String) -> [String: Any] {
        var props: [String: Any] = [:]
        let deeper = indent + " "
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            guard s.hasPrefix(indent), !s.hasPrefix(deeper) else { continue }
            let stripped = String(s.dropFirst(indent.count))
            guard let eqRange = stripped.range(of: " = ") else { continue }
            let key = String(stripped[..<eqRange.lowerBound])
            let valStr = String(stripped[eqRange.upperBound...])

            if valStr == "true" {
                props[key] = NSNumber(value: true)
            } else if valStr == "false" {
                props[key] = NSNumber(value: false)
            } else if valStr.hasPrefix("\""), valStr.hasSuffix("\""), valStr.count >= 2 {
                props[key] = String(valStr.dropFirst().dropLast())
            } else if let m = matchInt(valStr) {
                props[key] = NSNumber(value: m)
            }
        }
        return props
    }

    /// Extract the `WinningPowerSourceOption` sub-dict from the raw body of a
    /// `IOPortFeaturePowerSource` block in probe 17. Returns `[String: Int]`
    /// because the only values we need (Voltage, Current, Power) are integers.
    ///
    /// This is separate from `parseProperties` because the sub-dict uses a
    /// different indentation depth and requires special handling.
    public static func parseWinningOption(
        text: String,
        blockIndex: Int,
        classPrefix: String
    ) -> [String: Int]? {
        let pattern = "--- \(classPrefix)[\(blockIndex)] ---"
        guard let headerRange = text.range(of: pattern) else { return nil }
        var body = String(text[headerRange.upperBound...])
        for sep in ["\n---", "\n==="] {
            if let r = body.range(of: sep) { body = String(body[..<r.lowerBound]) }
        }
        let marker = "WinningPowerSourceOption: {"
        guard let start = body.range(of: marker) else { return nil }
        let afterBrace = body[start.upperBound...]
        guard let endBrace = afterBrace.range(of: "\n  }") else { return nil }
        let inner = String(afterBrace[..<endBrace.lowerBound])

        var result: [String: Int] = [:]
        for line in inner.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("    "), !s.hasPrefix("     ") else { continue }
            let stripped = String(s.dropFirst(4))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if let v = matchInt(valStr) { result[key] = v }
        }
        return result.isEmpty ? nil : result
    }

    /// Extract the `WinningPowerSourceOption` sub-dict from an `===`-style block
    /// (HPM deep-dive section of probe 17). The indentation is deeper here (6 spaces).
    public static func parseWinningOptionFromEqualsBlock(_ body: String) -> [String: Int]? {
        let marker = "WinningPowerSourceOption: {"
        guard let start = body.range(of: marker) else { return nil }
        let afterBrace = body[start.upperBound...]
        // End at "      }" (6-space close) or a new section
        guard let endBrace = afterBrace.range(of: "\n      }") else { return nil }
        let inner = String(afterBrace[..<endBrace.lowerBound])

        var result: [String: Int] = [:]
        for line in inner.split(separator: "\n") {
            let s = String(line)
            // Properties inside the sub-dict are indented 8 spaces
            guard s.hasPrefix("        "), !s.hasPrefix("         ") else { continue }
            let stripped = String(s.dropFirst(8))
            guard let colonRange = stripped.range(of: ": ") else { continue }
            let key = String(stripped[..<colonRange.lowerBound])
            let valStr = String(stripped[colonRange.upperBound...])
            if let v = matchInt(valStr) { result[key] = v }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Integer parsing

    /// Parse `N (0xHEX)` or plain integer strings, returning the integer value.
    public static func matchInt(_ s: String) -> Int? {
        if let spaceIdx = s.firstIndex(of: " ") {
            if let v = Int(s[..<spaceIdx]) { return v }
        }
        return Int(s)
    }
}
