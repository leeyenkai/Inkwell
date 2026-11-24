import Foundation
@testable import InkwellCore
@testable import InkwellDesign
import InkwellTemplate
import XCTest

final class CSSTokenTests: XCTestCase {
    func handmade() throws -> String {
        try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/css/handmade.css"), encoding: .utf8)
    }

    func testReadsAndEditsHandmadeStylesheet() throws {
        let css = try handmade()
        var doc = CSSTokenDocument(text: css)
        XCTAssertEqual(doc.text, css)
        XCTAssertEqual(doc.value("--bg-color"), "#1a1a1a")
        XCTAssertEqual(doc.value("--text-secondary"), "#b5b5b5")
        XCTAssertEqual(doc.tokens.first { $0.name == "--accent-color" }?.kind, .color)
        XCTAssertFalse(doc.hasDarkPalette)
        doc.set("--accent-color", to: "#ff8a5c")
        XCTAssertEqual(doc.text, css.replacingOccurrences(of: "--accent-color: #64b5f6;", with: "--accent-color: #ff8a5c;"))
        doc.set("--accent-color", to: "#ff8a5c")
        XCTAssertEqual(doc.text, css.replacingOccurrences(of: "--accent-color: #64b5f6;", with: "--accent-color: #ff8a5c;"))
    }

    func testAddsTokensAndDarkPalette() {
        var doc = CSSTokenDocument(text: ":root {\n    --bg: #fff; /* page */\n}\nbody { color: red; }\n")
        doc.set("--text", to: "#111")
        XCTAssertEqual(doc.text, ":root {\n    --bg: #fff; /* page */\n    --text: #111;\n}\nbody { color: red; }\n")
        doc.set("--bg", to: "#000", scheme: .dark)
        XCTAssertTrue(doc.hasDarkPalette)
        XCTAssertEqual(doc.value("--bg", scheme: .dark), "#000")
        XCTAssertEqual(doc.value("--bg", scheme: .light), "#fff")
        doc.set("--text", to: "#eee", scheme: .dark)
        XCTAssertTrue(doc.text.hasSuffix("@media (prefers-color-scheme: dark) {\n    :root {\n        --bg: #000;\n        --text: #eee;\n    }\n}\n"))
    }

    func testCommentsDoNotConfuseBlocks() {
        let doc = CSSTokenDocument(text: "/* :root { --fake: 1; } */\n:root{--a:1px;--b:2px}\n")
        XCTAssertEqual(doc.tokens.map(\.name), ["--a", "--b"])
        XCTAssertEqual(doc.value("--b"), "2px")
    }
}

final class ConfigEditorTests: XCTestCase {
    func fixtureConfig() throws -> String {
        try String(contentsOf: fixtureSite().appending(path: "_config.yml"), encoding: .utf8)
    }

    func testEditsKeepEverythingElse() throws {
        let text = try fixtureConfig()
        var config = ConfigDocument(text: text)
        XCTAssertEqual(config.text, text)
        config.set("title", raw: YAMLFormat.quoted("Sample Site"))
        XCTAssertEqual(config.text, text, "an equal value changes nothing")
        config.set("title", raw: YAMLFormat.quoted("New title"))
        XCTAssertEqual(config.text, text.replacingOccurrences(of: "title: Sample Site", with: "title: \"New title\""))
        config.set("inkwell.theme", raw: YAMLFormat.quoted("notebook"))
        config.set("inkwell.reading_time", raw: "true")
        config.set("inkwell.theme", raw: YAMLFormat.quoted("essayist"))
        XCTAssertTrue(config.text.hasSuffix("\ninkwell:\n  theme: \"essayist\"\n  reading_time: true\n"))
        XCTAssertEqual(config.value("inkwell.theme"), .string("essayist"))
        XCTAssertEqual(config.value("collections.notes.permalink"), .string("/notes/:title/"))
        config.set("description", raw: nil)
        XCTAssertNil(config.value("description"))
        XCTAssertEqual(SiteConfig(yaml: config.values).collections.count, 3)
    }

    func testNestedKeyUnderExistingParent() {
        var config = ConfigDocument(text: "author:\n  name: Me\n  email: me@example.com\n\nlang: en\n")
        config.set("author.name", raw: YAMLFormat.quoted("You"))
        config.set("author.url", raw: YAMLFormat.quoted("https://example.com"))
        XCTAssertEqual(config.text, "author:\n  name: \"You\"\n  email: me@example.com\n  url: \"https://example.com\"\n\nlang: en\n")
    }

    func testNavigationEditing() throws {
        let text = try String(contentsOf: fixtureSite().appending(path: "_data/navigation.yml"), encoding: .utf8)
        var nav = NavigationDocument(text: text)
        XCTAssertEqual(nav.entries.map(\.title), ["about", "notes", "sidenotes", "travel", "photos"])
        nav.move(from: 4, to: 1)
        nav.entries.append(NavigationEntry(title: "Now: 2026", url: "/now"))
        let written = nav.text
        XCTAssertTrue(written.hasPrefix("# Order here = order in the top nav.\n"))
        XCTAssertEqual(NavigationDocument(text: written).entries.map(\.title), ["about", "photos", "notes", "sidenotes", "travel", "Now: 2026"])
    }
}

final class ThemeTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-theme-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testBundledThemes() {
        let themes = ThemeManifest.bundled()
        XCTAssertEqual(themes.map(\.id), ["essayist", "notebook", "photo-journal", "minimal"])
        for theme in themes {
            XCTAssertEqual(theme.tokens.count, 13, theme.id)
            XCTAssertTrue(theme.tokens.filter { $0.kind == .color }.allSatisfy { $0.dark != nil }, theme.id)
        }
    }

    func testEveryThemeRendersEveryPage() throws {
        for (index, theme) in ThemeManifest.bundled().enumerated() {
            let plan = ThemeApplier.plan(theme: theme, siteRoot: temp)
            if index == 0 {
                XCTAssertTrue(plan.changes.contains { $0.path == "_layouts/post.html" && $0.oldText != nil }, "replaces the site's post layout")
            } else {
                XCTAssertEqual(Set(plan.changes.map(\.path)), ["assets/css/inkwell.css", "assets/css/inkwell-dark.css", "_config.yml"])
            }
            XCTAssertFalse(plan.changes.contains { $0.path.hasPrefix("_notes/") || $0.path.hasSuffix(".md") }, "never touches content")
            try plan.apply(to: temp)
            XCTAssertEqual(ThemeApplier.plan(theme: theme, siteRoot: temp).changes, [], "applying twice changes nothing")

            let site = try SiteLoader.load(temp)
            let builder = PreviewBuilder(site: site)
            for doc in site.documents {
                let text = try String(contentsOf: doc.fileURL, encoding: .utf8)
                let page = builder.render(text: text, relativePath: doc.relativePath, url: doc.url)
                XCTAssertEqual(page.unsupportedTags, [], "\(theme.id) \(doc.relativePath)")
                XCTAssertTrue(page.html.contains("/assets/css/inkwell.css"), "\(theme.id) \(doc.relativePath)")
                XCTAssertTrue(page.html.contains("class=\"site-nav\""), "\(theme.id) \(doc.relativePath)")
                XCTAssertTrue(page.html.contains("media=\"(prefers-color-scheme: dark)\""), "\(theme.id) \(doc.relativePath)")
            }
            let post = try XCTUnwrap(site.documents(in: "notes").first)
            let html = try builder.render(text: String(contentsOf: post.fileURL, encoding: .utf8), relativePath: post.relativePath, url: post.url).html
            XCTAssertTrue(html.contains("<h1 class=\"post-title\">A sample essay</h1>"), theme.id)
            XCTAssertTrue(html.contains("<p class=\"post-byline\">And a subtitle</p>"), theme.id)
            XCTAssertTrue(html.contains("<title>A sample essay · Sample Site</title>"), theme.id)
        }
    }

    func testHomeLayoutListsTheCollection() throws {
        let theme = try XCTUnwrap(ThemeManifest.named("photo-journal"))
        try ThemeApplier.plan(theme: theme, siteRoot: temp).apply(to: temp)
        let config = ConfigDocument(text: try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8))
        XCTAssertEqual(config.value("inkwell.home_style"), .string("cards"))
        XCTAssertEqual(config.value("inkwell.home_collection"), .string("sidenotes"), "the first collection with output")
        let site = try SiteLoader.load(temp)
        let home = "---\nlayout: home\ntitle: Home\nlist: notes\n---\n\nWelcome.\n"
        let html = PreviewBuilder(site: site).render(text: home, relativePath: "index.md", url: "/").html
        XCTAssertTrue(html.contains("post-list--cards"))
        let first = try XCTUnwrap(html.range(of: "A sample essay")), second = try XCTUnwrap(html.range(of: "Second note"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "newest first")
        XCTAssertTrue(html.contains("<title>Sample Site</title>"))
    }

    func testDesignTokensForThemesAndHandmadeCSS() throws {
        let theme = try XCTUnwrap(ThemeManifest.named("notebook"))
        try ThemeApplier.plan(theme: theme, siteRoot: temp).apply(to: temp)
        let tokens = try XCTUnwrap(DesignTokens.load(siteRoot: temp))
        XCTAssertEqual(tokens.theme?.id, "notebook")
        let accent = try XCTUnwrap(tokens.entries.first { $0.name == "--accent" })
        XCTAssertEqual(accent.label, "Accent")
        XCTAssertEqual(accent.dark, "#7FA4FF")
        try tokens.set("--accent", to: "#123456", scheme: .dark, siteRoot: temp)
        XCTAssertEqual(DesignTokens.load(siteRoot: temp)?.entries.first { $0.name == "--accent" }?.dark, "#123456")
        XCTAssertEqual(DesignTokens.load(siteRoot: temp)?.entries.first { $0.name == "--accent" }?.light, "#3D6CF0")

        let other = temp.appending(path: "handmade", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other.appending(path: "assets/css"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appending(path: "Fixtures/css/handmade.css"),
                                         to: other.appending(path: "assets/css/style.css"))
        let found = try XCTUnwrap(DesignTokens.load(siteRoot: other))
        XCTAssertNil(found.theme)
        XCTAssertEqual(found.lightFile, "assets/css/style.css")
        XCTAssertEqual(found.entries.first { $0.name == "--bg-color" }?.label, "Background")
        try found.set("--bg-color", to: "#fafafa", scheme: .dark, siteRoot: other)
        let css = try String(contentsOf: other.appending(path: "assets/css/style.css"), encoding: .utf8)
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark)"), "a hand-made theme gets a dark block")
        XCTAssertTrue(css.contains("--bg-color: #1a1a1a;"))
    }
}

final class PaletteTests: XCTestCase {
    func testLightModeBlocksAndInversion() {
        var doc = CSSTokenDocument(text: ":root {\n    --bg: #1a1a1a;\n}\n")
        doc.set("--bg", to: "#f5f5f5", scheme: .lightMode)
        XCTAssertTrue(doc.hasLightModePalette)
        XCTAssertFalse(doc.hasDarkPalette)
        XCTAssertEqual(doc.value("--bg", scheme: .lightMode), "#f5f5f5")
        XCTAssertEqual(doc.value("--bg", scheme: .light), "#1a1a1a")
        XCTAssertTrue(doc.text.contains("@media (prefers-color-scheme: light)"))
        XCTAssertEqual(DesignTokens.invertedLightness("#1a1a1a"), "#E5E5E5")
        XCTAssertEqual(DesignTokens.invertedLightness("#fff"), "#000000")
        let blue = DesignTokens.invertedLightness("#64b5f6")!
        XCTAssertLessThan(DesignTokens.luminance(blue)!, DesignTokens.luminance("#64b5f6")!)
        XCTAssertLessThan(DesignTokens.luminance("#1a1a1a")!, 0.05)
    }
}

final class SassVariableTests: XCTestCase {
    func testDefaultsAndOverrides() throws {
        let theme = FileManager.default.temporaryDirectory.appending(path: "inkwell-sass-theme-\(UUID().uuidString)", directoryHint: .isDirectory)
        let site = theme.appending(path: "site", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: theme) }
        try FileManager.default.createDirectory(at: theme.appending(path: "_sass"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: theme.appending(path: "assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try "$base-font-size:   16px !default;\n$brand-color:      #2a7ae2 !default;\n$grey-light: lighten($grey, 40%) !default;\n$local: 1px;\n"
            .write(to: theme.appending(path: "_sass/minima.scss"), atomically: true, encoding: .utf8)
        try "---\n# front matter\n---\n\n@import \"minima\";\n".write(to: theme.appending(path: "assets/main.scss"), atomically: true, encoding: .utf8)

        let tokens = try XCTUnwrap(DesignTokens.load(siteRoot: site, themeRoot: theme))
        XCTAssertFalse(tokens.supportsColorSchemes)
        XCTAssertEqual(tokens.entries.map(\.name), ["$base-font-size", "$brand-color", "$grey-light"])
        XCTAssertEqual(tokens.entries.first { $0.name == "$brand-color" }?.kind, .color)
        XCTAssertEqual(tokens.entries.first { $0.name == "$brand-color" }?.label, "Brand")
        XCTAssertEqual(tokens.entries.first { $0.name == "$grey-light" }?.kind, .other)

        try tokens.set("$brand-color", to: "#c0392b", scheme: .light, siteRoot: site)
        try tokens.set("$base-font-size", to: "18px", scheme: .light, siteRoot: site)
        try tokens.set("$brand-color", to: "#8e44ad", scheme: .light, siteRoot: site)
        let main = try String(contentsOf: site.appending(path: "assets/main.scss"), encoding: .utf8)
        XCTAssertEqual(main, "---\n# front matter\n---\n\n$brand-color: #8e44ad;\n$base-font-size: 18px;\n@import \"minima\";\n")
        let reloaded = try XCTUnwrap(DesignTokens.load(siteRoot: site, themeRoot: theme))
        XCTAssertEqual(reloaded.entries.first { $0.name == "$brand-color" }?.light, "#8e44ad")
        XCTAssertEqual(reloaded.entries.first { $0.name == "$base-font-size" }?.light, "18px")
    }
}
