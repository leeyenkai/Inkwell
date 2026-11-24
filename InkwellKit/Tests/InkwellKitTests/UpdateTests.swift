import Foundation
@testable import InkwellCore
@testable import InkwellGitHub
@testable import InkwellSync
@testable import InkwellTemplate
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

final class RobustnessTests: XCTestCase {
    func testOddContentDoesNotCrash() {
        XCTAssertNil(ThemeReference.of(SiteConfig(yaml: YAML.parse("remote_theme: \"\"\n"))))
        _ = LiquidTemplate("a {{-}} b {%-%} c {{ - }}")
    }

    func testASiteWithoutConfigOrPostsCanStart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SiteLoader.load(root))
        try Data("# Hello\n".utf8).write(to: root.appending(path: "index.md"))
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.sections.first?.collectionName, "posts")
    }

    func testFilenameUsesTheSiteCalendarDay() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T03:00:00Z"))
        XCTAssertEqual(Filename.make(date: instant, slug: "a", timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))), "2026-11-25-a.md")
        XCTAssertEqual(Filename.make(date: instant, slug: "a", timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))),
                       "2026-11-24-a.md")
    }

    func testOlderStateStillReads() throws {
        let json = #"{"ref":{"owner":"o","name":"r","branch":"main"},"baseCommit":"c","baseTree":"t","files":{"a.md":"x"}}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        XCTAssertEqual(state.ref.sitePath, "")
        XCTAssertEqual(state.files["a.md"], "x")
        XCTAssertTrue(state.conflicts.isEmpty)
    }
}
