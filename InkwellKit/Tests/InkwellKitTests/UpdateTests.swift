import Foundation
@testable import InkwellGitHub
import XCTest

final class UpdateTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(UpdateCheck.isNewer("0.10", than: "0.9"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "1.0-beta.3"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0-beta.10", than: "1.0-beta.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.9.1"))
    }

    func testReadsTheLatestRelease() async throws {
        let json = """
        {"tag_name": "v0.9.1", "name": "Inkwell 0.9.1", "body": "Fixes.\\n", "html_url": "https://github.com/o/r/releases/tag/v0.9.1",
         "assets": [{"name": "Inkwell-0.9.1.dmg.sha256", "browser_download_url": "https://example.com/a.sha256"},
                    {"name": "Inkwell-0.9.1.dmg", "browser_download_url": "https://example.com/Inkwell-0.9.1.dmg"}]}
        """
        let file = FileManager.default.temporaryDirectory.appending(path: "release-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let latest = try await UpdateCheck.latest(feed: file)
        let release = try XCTUnwrap(latest)
        XCTAssertEqual(release.version, "0.9.1")
        XCTAssertEqual(release.notes, "Fixes.")
        XCTAssertEqual(release.download.absoluteString, "https://example.com/Inkwell-0.9.1.dmg")
        XCTAssertEqual(UpdateCheck.feed(repository: "o/r")?.absoluteString, "https://api.github.com/repos/o/r/releases/latest")
    }
}
