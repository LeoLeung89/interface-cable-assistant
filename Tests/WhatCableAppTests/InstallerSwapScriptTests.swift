import XCTest
@testable import WhatCable

/// Regression cover for issue #339: the self-update swap script must only ever
/// delete its own per-update folder, never the shared temp root that folder
/// sits in. The old script ran `rm -rf "$(dirname "$0")"` against the temp
/// root and wiped every other app's temp files.
final class InstallerSwapScriptTests: XCTestCase {
    // A realistic per-update folder: a sibling inside the shared temp root.
    private let tempRoot = "/var/folders/q6/abc123/T"
    private let workDir = "/var/folders/q6/abc123/T/whatcable-update-DEADBEEF"

    private func script() -> String {
        Installer.makeSwapScript(
            pid: 4242,
            newPath: "\(workDir)/WhatCable.app",
            oldPath: "/Applications/WhatCable.app",
            workDirPath: workDir
        )
    }

    func testCleanupTargetsTheWorkDirExactly() {
        XCTAssertTrue(
            script().contains("rm -rf '\(workDir)'"),
            "Cleanup must remove the per-update work dir verbatim"
        )
    }

    func testCleanupNeverTargetsTheTempRoot() {
        let s = script()
        // The folder's parent (the shared temp root) must never be an rm target.
        XCTAssertFalse(s.contains("rm -rf '\(tempRoot)'"))
        XCTAssertFalse(s.contains("rm -rf \"\(tempRoot)\""))
        // The dirname-based deletion that caused #339 must be gone entirely.
        XCTAssertFalse(s.contains("dirname"))
    }

    func testWorkDirPathIsSingleQuotedAgainstSpaces() {
        let spaced = Installer.makeSwapScript(
            pid: 1,
            newPath: "/tmp/x/WhatCable.app",
            oldPath: "/Applications/WhatCable.app",
            workDirPath: "/var/folders/q6/abc/T/whatcable update DEADBEEF"
        )
        XCTAssertTrue(spaced.contains("rm -rf '/var/folders/q6/abc/T/whatcable update DEADBEEF'"))
    }
}
