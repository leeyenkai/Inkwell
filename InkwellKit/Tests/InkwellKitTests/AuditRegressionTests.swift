import Foundation
@testable import InkwellCore
import XCTest

/// Problems a review of the 0.11 audit fixes found in the fixes themselves.
final class AuditRegressionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inkwell-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testIncludeListAtTheKeysOwnIndentationStaysValid() throws {
        let config = "title: X\ninclude:\n- _b\nexclude:\n- vendor\n"
        let updated = try XCTUnwrap(JekyllAdoption.including(["_data2", "_b"], in: config))
        XCTAssertEqual(updated, "title: X\ninclude:\n- _b\n- \"_data2\"\nexclude:\n- vendor\n")
        let parsed = YAML.parse(updated)
        XCTAssertEqual(parsed["include"]?.list?.compactMap(\.string), ["_b", "_data2"])
        XCTAssertEqual(parsed["exclude"]?.list?.compactMap(\.string), ["vendor"])
    }

    func testRedirectsWorkOnBranchBuiltSitesWhateverTheGemfile() throws {
        // The Gemfile `jekyll new` writes: github-pages commented out, no redirect gem.
        try Data("source \"https://rubygems.org\"\ngem \"jekyll\", \"~> 4.3\"\n# gem \"github-pages\"\n".utf8).write(to: root.appending(path: "Gemfile"))
        XCTAssertTrue(Plugins.usable("jekyll-redirect-from", siteRoot: root), "GitHub's own build ignores the Gemfile")
        let workflows = root.appending(path: ".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try Data("""
        jobs:
          build:
            steps:
              - run: bundle exec jekyll build
              - uses: actions/upload-pages-artifact@v3
        """.utf8).write(to: workflows.appending(path: "pages.yml"))
        XCTAssertFalse(Plugins.usable("jekyll-redirect-from", siteRoot: root), "its own Jekyll build only has the Gemfile's gems")
    }
}
