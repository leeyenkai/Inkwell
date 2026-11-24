import Foundation
@testable import InkwellCore
@testable import InkwellGitHub
@testable import InkwellSync
@testable import InkwellTemplate
import XCTest

let bundledSass: SassCompiler? = {
    let path = ProcessInfo.processInfo.environment["INKWELL_SASS"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/InkwellBuild/engines/dart-sass-1.108.2/dart-sass/sass").path
    return FileManager.default.isExecutableFile(atPath: path) ? SassCompiler(executable: URL(fileURLWithPath: path)) : nil
}()

final class SiteResourcesTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-resources-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files: [String: String] = [
            "site/_config.yml": "title: Themed\ntheme: minima\nbaseurl: \"/blog\"\n",
            "site/index.md": "---\ntitle: Home\n---\n\nWelcome.\n",
            "site/about.md": "---\ntitle: About\n---\n\nAbout me.\n",
            "site/_posts/2026-01-02-first.md": "---\ntitle: First\n---\n\nPost one.\n",
            "site/_posts/2026-03-04-second.md": "---\ntitle: Second\n---\n\nPost two.\n",
            "site/feed.xml": "---\nlayout: null\n---\n<feed>{% for post in site.posts %}<t>{{ post.title }}</t>{% endfor %}</feed>\n",
            "site/assets/photo.txt": "plain",
            "theme/_layouts/default.html": "<html><head><link href=\"{{ '/assets/main.css' | relative_url }}\"></head>"
                + "<body>{% include nav.html %}{{ content }}</body></html>\n",
            "theme/_layouts/home.html": "---\nlayout: default\n---\n<section class=\"home\">{{ content }}<ul>"
                + "{% for post in site.posts %}<li>{{ post.title }}</li>{% endfor %}</ul></section>\n",
            "theme/_layouts/post.html": "---\nlayout: default\n---\n<article class=\"post\">{{ content }}</article>\n",
            "theme/_layouts/page.html": "---\nlayout: default\n---\n<div class=\"page\">{{ content }}</div>\n",
            "theme/_includes/nav.html": "<nav>{{ site.title }}</nav>",
            "theme/_sass/base.scss": "$accent: #336699;\n.nav { color: $accent; a { color: darken($accent, 10%); } }\n",
            "theme/assets/main.scss": "---\n---\n@import \"base\";\nbody { margin: {{ 2 | plus: 2 }}px; }\n",
        ]
        for (path, text) in files {
            let url = temp.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func resources() throws -> SiteResources {
        let site = try SiteLoader.load(temp.appending(path: "site"))
        return SiteResources(builder: PreviewBuilder(site: site, themeRoot: temp.appending(path: "theme")), themeRoot: temp.appending(path: "theme"),
                             sass: bundledSass)
    }

    func text(_ r: SiteResources.Response) -> String { String(decoding: r.data, as: UTF8.self) }

    func testThemeReferences() {
        XCTAssertEqual(ThemeReference.of(SiteConfig(yaml: YAML.parse("theme: minima"))),
                       ThemeReference(owner: "jekyll", repository: "minima", ref: "v2.5.1"))
        XCTAssertEqual(ThemeReference.of(SiteConfig(yaml: YAML.parse("theme: jekyll-theme-cayman")))?.repository, "cayman")
        XCTAssertEqual(ThemeReference.of(SiteConfig(yaml: YAML.parse("remote_theme: owner/fancy@v1"))),
                       ThemeReference(owner: "owner", repository: "fancy", ref: "v1"))
        XCTAssertNil(ThemeReference.of(SiteConfig(yaml: YAML.parse("theme: unknown-gem"))))
    }

    func testPagesUseThemeLayoutsAndDefaults() throws {
        let r = try resources()
        let home = text(r.response(for: "/blog/"))
        XCTAssertTrue(home.contains("<section class=\"home\">"), "index.md gets the home layout by default")
        XCTAssertTrue(home.contains("<nav>Themed</nav>"), "includes come from the theme")
        let second = try XCTUnwrap(home.range(of: "Second")), first = try XCTUnwrap(home.range(of: "First"))
        XCTAssertLessThan(second.lowerBound, first.lowerBound, "site.posts is newest first")
        XCTAssertTrue(text(r.response(for: "/blog/about.html")).contains("<div class=\"page\">"))
        XCTAssertTrue(text(r.response(for: "/blog/about")).contains("About me."))
        XCTAssertTrue(text(r.response(for: "/blog/2026/03/04/second.html")).contains("<article class=\"post\">"))
        let feed = r.response(for: "/blog/feed.xml")
        XCTAssertEqual(text(feed), "<feed><t>Second</t><t>First</t></feed>\n")
        XCTAssertEqual(feed.mimeType, "application/xml")
        XCTAssertEqual(text(r.response(for: "/blog/assets/photo.txt")), "plain")
        XCTAssertEqual(r.response(for: "/blog/nowhere").status, 404)
        XCTAssertEqual(r.response(for: "/blog/_config.yml").status, 404, "underscore folders are never served")
    }

    func testSassIsCompiled() throws {
        guard bundledSass != nil else { throw XCTSkip("Run scripts/fetch-engines.sh to test Sass.") }
        let css = text(try resources().response(for: "/blog/assets/main.css"))
        XCTAssertTrue(css.contains("color: #336699"), css)
        XCTAssertTrue(css.contains(".nav a"), css)
        XCTAssertTrue(css.contains("margin: 4px"), "Liquid runs before Sass")
    }
}

/// Downloads the real minima theme and renders a minima-style blog. Skipped unless INKWELL_LIVE_TOKEN is set.
final class LiveThemeTests: XCTestCase {
    func testMinimaRenders() async throws {
        guard let token = ProcessInfo.processInfo.environment["INKWELL_LIVE_TOKEN"] else { throw XCTSkip("Set INKWELL_LIVE_TOKEN to run.") }
        let cache = ThemeCache(folder: FileManager.default.temporaryDirectory.appending(path: "inkwell-themes-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: cache.folder) }
        let theme = try await cache.ensure(owner: "jekyll", repository: "minima", ref: "v2.5.1", client: GitHubClient(token: token))
        let site = FileManager.default.temporaryDirectory.appending(path: "inkwell-minima-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: site) }
        for (path, text) in ["_config.yml": "title: Minima test\ntheme: minima\n", "index.md": "---\nlayout: home\n---\n",
                             "about.md": "---\nlayout: page\ntitle: About\npermalink: /about/\n---\nAbout.\n",
                             "_posts/2026-01-02-hello.md": "---\nlayout: post\ntitle: Hello\n---\nHi.\n"] {
            let url = site.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let loaded = try SiteLoader.load(site)
        let resources = SiteResources(builder: PreviewBuilder(site: loaded, themeRoot: theme), themeRoot: theme, sass: bundledSass)
        let home = String(decoding: resources.response(for: "/").data, as: UTF8.self)
        XCTAssertTrue(home.contains("site-header"), "minima's header include rendered")
        XCTAssertTrue(home.contains("Hello"), "the post is listed")
        XCTAssertTrue(home.contains("About"), "pages are in minima's menu")
        if bundledSass != nil {
            let css = String(decoding: resources.response(for: "/assets/main.css").data, as: UTF8.self)
            XCTAssertTrue(css.contains(".site-header"), "minima's Sass compiled")
            XCTAssertFalse(css.hasPrefix("/* Sass"), css.prefix(300).description)
        }
    }
}
