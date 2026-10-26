import XCTest
@testable import WhatCable

/// Cover for `UpdateChecker.parseRelease`, the shared JSON parser used by both
/// the background poll and the pre-install re-check added for issue #372.
final class UpdateReleaseParseTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesTagVersionAndDownloadAsset() {
        let json = """
        {
          "tag_name": "v1.1.6",
          "html_url": "https://github.com/darrylmorley/whatcable/releases/tag/v1.1.6",
          "body": "Release notes",
          "assets": [
            {"name": "WhatCable.zip", "browser_download_url": "https://objects.githubusercontent.com/github-production-release-asset/abc/WhatCable.zip"}
          ]
        }
        """
        let release = UpdateChecker.parseRelease(from: data(json))
        XCTAssertEqual(release?.version, "1.1.6", "Leading v must be stripped")
        XCTAssertEqual(release?.notes, "Release notes")
        XCTAssertEqual(
            release?.downloadURL?.absoluteString,
            "https://objects.githubusercontent.com/github-production-release-asset/abc/WhatCable.zip",
            "Asset on GitHub's release CDN host is accepted"
        )
    }

    func testRejectsDownloadAssetFromUntrustedHost() {
        let json = """
        {
          "tag_name": "v1.1.6",
          "html_url": "https://github.com/darrylmorley/whatcable/releases/tag/v1.1.6",
          "assets": [
            {"name": "WhatCable.zip", "browser_download_url": "https://evil.example.com/WhatCable.zip"}
          ]
        }
        """
        let release = UpdateChecker.parseRelease(from: data(json))
        XCTAssertNotNil(release, "A release with an untrusted asset still parses")
        XCTAssertNil(release?.downloadURL, "Asset from an untrusted host must be dropped")
    }

    func testReturnsNilWhenRequiredFieldsMissing() {
        XCTAssertNil(UpdateChecker.parseRelease(from: data("{}")))
        XCTAssertNil(UpdateChecker.parseRelease(from: data("not json")))
        // tag present but no html_url
        XCTAssertNil(UpdateChecker.parseRelease(from: data(#"{"tag_name": "v1.1.6"}"#)))
    }

    func testParsesWhenNoMatchingAsset() {
        let json = """
        {
          "tag_name": "1.2.0",
          "html_url": "https://github.com/x/y/releases/tag/1.2.0",
          "assets": [
            {"name": "whatcable-cli-1.2.0.zip", "browser_download_url": "https://github.com/x/y/cli.zip"}
          ]
        }
        """
        let release = UpdateChecker.parseRelease(from: data(json))
        XCTAssertEqual(release?.version, "1.2.0", "Tag without a v prefix is taken as-is")
        XCTAssertNil(release?.downloadURL, "Only the WhatCable.zip asset counts as the app download")
    }

    // MARK: - Pre-release backstop

    func testRejectsPrerelease() {
        let json = """
        {
          "tag_name": "v1.2.0-beta.1",
          "html_url": "https://github.com/darrylmorley/whatcable/releases/tag/v1.2.0-beta.1",
          "prerelease": true
        }
        """
        XCTAssertNil(
            UpdateChecker.parseRelease(from: data(json)),
            "A pre-release must never be offered as an update, even if it somehow reaches this parser"
        )
    }

    func testParsesWhenPrereleaseIsExplicitlyFalse() {
        let json = """
        {
          "tag_name": "v1.1.6",
          "html_url": "https://github.com/darrylmorley/whatcable/releases/tag/v1.1.6",
          "prerelease": false
        }
        """
        let release = UpdateChecker.parseRelease(from: data(json))
        XCTAssertEqual(release?.version, "1.1.6", "Leading v must be stripped")
    }

    func testParsesWhenPrereleaseKeyAbsent() {
        let json = """
        {
          "tag_name": "v1.1.6",
          "html_url": "https://github.com/darrylmorley/whatcable/releases/tag/v1.1.6"
        }
        """
        let release = UpdateChecker.parseRelease(from: data(json))
        XCTAssertEqual(release?.version, "1.1.6", "Missing prerelease key must still parse, for backwards compatibility")
    }
}
