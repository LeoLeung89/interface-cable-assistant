import XCTest
@testable import WhatCable

/// Cover for `Installer.resolveLatest`, the pre-install re-check added for
/// issue #372. The fetch is injected so the fallback logic is exercised without
/// touching the network.
@MainActor
final class InstallerResolveLatestTests: XCTestCase {
    private func update(_ version: String, asset: Bool = true) -> AvailableUpdate {
        AvailableUpdate(
            version: version,
            url: URL(string: "https://github.com/darrylmorley/whatcable/releases/tag/v\(version)")!,
            downloadURL: asset
                ? URL(string: "https://objects.githubusercontent.com/x/WhatCable.zip")
                : nil,
            notes: "notes \(version)"
        )
    }

    func testFallsBackToOriginalWhenFetchFails() async {
        let original = update("1.1.5")
        let result = await Installer.shared.resolveLatest(original) { nil }
        XCTAssertEqual(result, original, "A failed re-check must install the version we were handed")
    }

    func testFallsBackWhenReCheckIsSameVersion() async {
        let original = update("1.1.6")
        let result = await Installer.shared.resolveLatest(original) { self.update("1.1.6") }
        XCTAssertEqual(result, original, "Equal version keeps the original update, notes and asset intact")
    }

    func testFallsBackWhenReCheckIsOlder() async {
        let original = update("1.1.6")
        let result = await Installer.shared.resolveLatest(original) { self.update("1.1.5") }
        XCTAssertEqual(result, original, "An older re-check result must never downgrade the install")
    }

    func testFallsBackWhenNewerHasNoDownloadAsset() async {
        let original = update("1.1.5")
        let result = await Installer.shared.resolveLatest(original) { self.update("1.1.6", asset: false) }
        XCTAssertEqual(result, original, "A newer release with no download asset must not replace the original")
    }

    func testSwapsToNewerVersionWithAsset() async {
        let original = update("1.1.5")
        let newer = update("1.1.6")
        let result = await Installer.shared.resolveLatest(original) { newer }
        XCTAssertEqual(result, newer, "A newer release with an asset is installed instead of the stale one")
    }
}
