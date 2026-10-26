import Foundation
import Testing
@testable import WhatCableDarwinBackend

/// The watcher passes `kUSBContainerID` through untouched. What an ID is
/// worth (absent, all-zero, a shared template) is decided in Core.
@Suite("USBWatcher: Container ID read")
struct USBWatcherContainerIDTests {

    @Test("kUSBContainerID is read exactly as published")
    func readsPublishedValue() {
        // A Container ID as `ioreg -p IOUSB -l` prints one (made-up value).
        let dict: [String: Any] = [
            "idVendor": NSNumber(value: 0x1D5C),
            "kUSBContainerID": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        ]
        #expect(USBWatcher.containerID(from: dict) == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    }

    @Test("An absent or non-string value reads as nil")
    func absentOrWrongTypeIsNil() {
        #expect(USBWatcher.containerID(from: [:]) == nil)
        #expect(USBWatcher.containerID(from: ["kUSBContainerID": NSNumber(value: 1)]) == nil)
    }
}
