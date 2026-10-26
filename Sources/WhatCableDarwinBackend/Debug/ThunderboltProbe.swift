import Foundation
import IOKit
import WhatCableCore

/// Read-only IOKit walker that dumps the IOIOThunderboltSwitch tree as plain
/// text. Used by `whatcable --tb-debug` to gather field shapes from real
/// Thunderbolt hardware so we can design the rendering layer with evidence
/// rather than guesses. No interpretation, no rendering, just a paste-ready
/// dump of every property on every switch and port.
public enum ThunderboltProbe {
    /// Dumps the discovered Thunderbolt switch tree as paste-ready text.
    public static func dump() -> String {
        var output = ""
        output += "# WhatCable Thunderbolt probe\n"
        output += "# whatcable \(AppInfo.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        output += "# Generated \(ISO8601DateFormatter().string(from: Date()))\n"
        output += "\n"

        // Apple uses two naming families for the abstract parent class:
        // `IOIOThunderboltSwitch*` on older Macs / older macOS, and
        // `IOThunderboltSwitch*` on M5 / macOS 26 onward. Match each and
        // dedup by entry ID so the same service isn't dumped twice.
        let matchClasses = ["IOIOThunderboltSwitch", "IOThunderboltSwitch"]
        var seen: Set<UInt64> = []
        var switchCount = 0

        for matchClassName in matchClasses {
            let matching = IOServiceMatching(matchClassName)
            var iter: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
            guard kr == KERN_SUCCESS else {
                output += "ERROR: IOServiceGetMatchingServices(\"\(matchClassName)\") returned \(kr)\n"
                continue
            }
            defer { IOObjectRelease(iter) }

            var attempt = 0
            while true {
                attempt += 1
                let seenSnapshot = seen
                let outputSnapshot = output
                let switchCountSnapshot = switchCount
                var sawAny = false
                var next = IOIteratorNext(iter)
                while next != 0 {
                    sawAny = true
                    let service = next
                    defer { IOObjectRelease(service) }
                    var entryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &entryID)
                    if seen.insert(entryID).inserted {
                        switchCount += 1
                        output += dumpSwitch(service, index: switchCount)
                        output += "\n"
                    }
                    next = IOIteratorNext(iter)
                }
                let invalidatedMidWalk = sawAny && IOIteratorIsValid(iter) == 0
                if !invalidatedMidWalk || attempt >= 3 { break }
                // Discard this pass and re-walk from the start. IOIteratorReset
                // rewinds to the beginning of the list, so keeping what this
                // pass already added to `seen`/`output`/`switchCount` would
                // double count everything once the re-walk reaches it again.
                seen = seenSnapshot
                output = outputSnapshot
                switchCount = switchCountSnapshot
                IOIteratorReset(iter)
            }
        }

        if switchCount == 0 {
            output += "No Thunderbolt switch services found.\n"
            output += "(This is unexpected on Apple Silicon. Please flag in the issue.)\n"
        } else {
            output += "# \(switchCount) switch(es) total\n"
        }
        return output
    }

    /// Renders one Thunderbolt switch and its port children.
    private static func dumpSwitch(_ service: io_service_t, index: Int) -> String {
        var output = ""
        let className = TerminalFieldEncoder.encode(ioClassName(service) ?? "<unknown class>")
        output += "## Switch #\(index): \(className)\n"

        if let props = ioProperties(service) {
            output += renderProperties(props, indent: "  ")
        }

        // Walk port children.
        var childIter: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter)
        guard kr == KERN_SUCCESS else {
            output += "  ERROR: child iterator failed (\(kr))\n"
            return output
        }
        defer { IOObjectRelease(childIter) }

        var portIndex = 0
        var attempt = 0
        while true {
            attempt += 1
            let outputSnapshot = output
            let portIndexSnapshot = portIndex
            var sawAny = false
            var next = IOIteratorNext(childIter)
            while next != 0 {
                sawAny = true
                let child = next
                defer { IOObjectRelease(child) }
                let childClass = ioClassName(child) ?? "<unknown>"
                // Filter to IOIOThunderboltPort and its subclasses. Skip the adapter
                // children (AppleThunderboltUSBDownAdapter etc.) — they're driver
                // matches, not link-state carriers.
                if childClass.contains("Port") {
                    portIndex += 1
                    output += "\n  ### Port @\(portIndex): \(TerminalFieldEncoder.encode(childClass))\n"
                    if let props = ioProperties(child) {
                        output += renderProperties(props, indent: "    ")
                    }
                }
                next = IOIteratorNext(childIter)
            }
            let invalidatedMidWalk = sawAny && IOIteratorIsValid(childIter) == 0
            if !invalidatedMidWalk || attempt >= 3 { break }
            // Discard this pass and re-walk from the start. IOIteratorReset
            // rewinds to the beginning of the list, so keeping what this pass
            // already appended to `output`/`portIndex` would double count it
            // once the re-walk reaches it again.
            output = outputSnapshot
            portIndex = portIndexSnapshot
            IOIteratorReset(childIter)
        }
        return output
    }

    /// Reads the IOKit class name for a service, if available.
    private static func ioClassName(_ service: io_service_t) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        let kr = IOObjectGetClass(service, &buf)
        guard kr == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }

    /// Copies the service's IOKit properties into a Swift dictionary.
    private static func ioProperties(_ service: io_service_t) -> [String: Any]? {
        // ThunderboltProbe is a diagnostic helper (`--tb-debug`). It intentionally
        // reads the entire property dict so it can render all keys verbatim.
        // The keys are not known in advance, so per-key reads are not feasible.
        // TB switch services are persistent during the probe lifetime, so the
        // IOCFUnserializeBinary teardown crash (issue #181) does not apply.
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    /// Renders sorted, terminal-safe property keys and recursively formatted values.
    static func renderProperties(_ props: [String: Any], indent: String) -> String {
        // Sort keys for stable, paste-friendly output. Skip noisy fields that
        // don't help with the design (IOPowerManagement dict, large binary blobs
        // that aren't useful without decoding).
        let skip: Set<String> = ["IOPowerManagement"]
        var output = ""
        for key in props.keys.sorted() where !skip.contains(key) {
            let value = props[key]!
            output += "\(indent)\(TerminalFieldEncoder.encode(key)) = \(renderValue(value))\n"
        }
        return output
    }

    /// Formats a scalar, collection, or data property for diagnostic output.
    private static func renderValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            return "\"\(TerminalFieldEncoder.encode(s))\""
        case let n as NSNumber:
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        case let data as Data:
            // Hex dump short blobs; truncate long ones.
            let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined()
            let suffix = data.count > 64 ? "...(\(data.count) bytes total)" : ""
            return "<\(hex)\(suffix)>"
        case let arr as [Any]:
            let parts = arr.map { renderValue($0) }
            return "[\(parts.joined(separator: ", "))]"
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().map {
                "\(TerminalFieldEncoder.encode($0))=\(renderValue(dict[$0]!))"
            }
            return "{\(parts.joined(separator: ", "))}"
        default:
            return TerminalFieldEncoder.encode("\(value)")
        }
    }
}
