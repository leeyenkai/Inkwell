import Foundation
@testable import InkwellCore
@testable import InkwellDesign
import InkwellTemplate
import XCTest

/// The six bundled themes on the sample site, their accessibility, the palettes and font pairings, and theme trials.
final class ThemeGalleryTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-gallery-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func render(_ path: String, in root: URL) throws -> String {
        let site = try SiteLoader.load(root)
        let builder = PreviewBuilder(site: site, timeZone: TimeZone(identifier: "UTC")!)
        let resources = SiteResources(builder: builder, themeRoot: nil, sass: nil)
        let response = resources.response(for: path)
        XCTAssertEqual(response.status, 200, path)
        return String(bytes: response.data, encoding: .utf8) ?? ""
    }

    func testSampleSiteIsNotATheme() throws {
        let ids = ThemeManifest.bundled().map(\.id)
        XCTAssertFalse(ids.contains("_sample"))
        XCTAssertFalse(ids.contains("_base"))
        let sample = ThemeManifest.sampleSite
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.appending(path: "_config.yml").path))
        let posts = try FileManager.default.contentsOfDirectory(atPath: sample.appending(path: "_posts").path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertGreaterThanOrEqual(posts.count, 5)
        let images = try FileManager.default.contentsOfDirectory(at: sample.appending(path: "assets/images"),
                                                                 includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertGreaterThanOrEqual(images.count, 5)
        for image in images {
            let size = try XCTUnwrap(image.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertLessThan(size, 60000, image.lastPathComponent)
        }
    }

    func testThemesHaveEveryTokenAndReadableColours() {
        let required = ["--bg", "--surface", "--text", "--muted", "--accent", "--border", "--font-body", "--font-heading", "--font-mono",
                        "--font-size", "--line-height", "--width", "--radius"]
        for theme in ThemeManifest.bundled() {
            XCTAssertTrue(Set(theme.tokens.map(\.name)).isSuperset(of: required), theme.id)
            XCTAssertFalse(theme.summary.isEmpty, theme.id)
            for palette in DesignPresets.palettes(for: theme) {
                assertReadable(palette, "\(theme.id)/\(palette.id)")
            }
            let size = theme.tokens.first { $0.name == "--font-size" }?.light ?? ""
            XCTAssertGreaterThanOrEqual(Double(size.dropLast(2)) ?? 0, 15, "\(theme.id): text is at least 15px")
        }
    }

    func assertReadable(_ palette: ColorPalette, _ name: String) {
        for dark in [false, true] {
            for background in ["--bg", "--surface"] {
                let bg = palette.value(background, dark: dark) ?? ""
                for (token, needed) in [("--text", 7.0), ("--muted", 4.5), ("--accent", 4.5)] {
                    let ratio = DesignPresets.contrast(palette.value(token, dark: dark) ?? "", bg) ?? 0
                    XCTAssertGreaterThanOrEqual(ratio, needed, "\(name) \(dark ? "dark" : "light"): \(token) on \(background)")
                }
            }
        }
    }

    func testThemeStringsAreInTheThemesTable() throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/InkwellDesign/Themes.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let keys = Set(try XCTUnwrap(json["strings"] as? [String: Any]).keys)
        for folder in try FileManager.default.contentsOfDirectory(at: ThemeManifest.themesFolder, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: folder.appending(path: "theme.json")) else { continue }
            let theme = try JSONDecoder().decode(ThemeManifest.self, from: data)
            var texts = [theme.summary] + theme.tokens.flatMap { [$0.label, $0.group] } + theme.options.map(\.label)
            texts.removeAll { keys.contains($0) }
            XCTAssertEqual(texts, [], "\(theme.id): missing from Themes.xcstrings")
        }
    }

    func testEveryThemeOnTheSampleSite() throws {
        let markers = [
            "essayist": "class=\"home-intro\"", "notebook": "class=\"shell\"", "photo-journal": "class=\"photo-grid\"",
            "minimal": "post-list--list", "magazine": "class=\"lead-story\"", "studio": "class=\"hero\"",
        ]
        for theme in ThemeManifest.bundled() {
            let root = temp.appending(path: theme.id)
            try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: root)
            let home = try render("/", in: root)
            XCTAssertTrue(home.contains(markers[theme.id] ?? "<html"), "\(theme.id) home")
            XCTAssertTrue(home.contains("Field Notes"), theme.id)
            XCTAssertTrue(home.contains("The long way round the headland"), theme.id)
            XCTAssertTrue(home.contains("class=\"site-nav\""), theme.id)
            XCTAssertTrue(home.contains("<link rel=\"stylesheet\" href=\"/assets/css/inkwell-blocks.css\">"), theme.id)
            XCTAssertTrue(home.contains("<script src=\"/assets/js/inkwell-blocks.js\" defer></script>"), theme.id)
            XCTAssertTrue(home.contains("href=\"#content\""), "\(theme.id) has a skip link")
            XCTAssertFalse(home.contains("{{") || home.contains("{%"), "\(theme.id) left Liquid unrendered")

            let post = try render("/2026/10/the-long-way-round-the-headland/", in: root)
            XCTAssertTrue(post.contains("<h1 class=\"post-title\">The long way round the headland</h1>"), theme.id)
            XCTAssertTrue(post.contains("/assets/images/harbour.jpg"), theme.id)
            let about = try render("/about/", in: root)
            XCTAssertTrue(about.contains("<h1 class=\"page-title\">About</h1>"), theme.id)
            let writing = try render("/writing/", in: root)
            XCTAssertTrue(writing.contains("Meadows in July"), theme.id)
        }
    }

    func testCoverFallsBackToTheFirstImage() throws {
        let theme = try XCTUnwrap(ThemeManifest.named("studio"))
        try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: temp)
        let post = temp.appending(path: "_posts/2026-08-30-a-week-in-the-pine-forest.md")
        let text = try String(contentsOf: post, encoding: .utf8).replacingOccurrences(of: "image: /assets/images/forest.jpg\n", with: "")
        try text.write(to: post, atomically: true, encoding: .utf8)
        let home = try render("/", in: temp)
        XCTAssertTrue(home.contains("<img src=\"/assets/images/meadow.jpg\" alt=\"\" loading=\"lazy\">"), "the first image in the text")
    }

    func testPageOptionsAndOtherLayouts() throws {
        for theme in ThemeManifest.bundled() {
            let root = temp.appending(path: theme.id)
            try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: root)
            try "---\nlayout: page\ntitle: Wide one\nwide: true\nhide_title: true\n---\n\nWide text.\n"
                .write(to: root.appending(path: "wide.md"), atomically: true, encoding: .utf8)
            try "---\nlayout: default\n---\n<div class=\"album-grid\">{{ content }}</div>\n"
                .write(to: root.appending(path: "_layouts/album.html"), atomically: true, encoding: .utf8)
            try "---\nlayout: album\ntitle: Trip\n---\n\nPhotos.\n"
                .write(to: root.appending(path: "trip.md"), atomically: true, encoding: .utf8)
            let wide = try render("/wide/", in: root)
            XCTAssertTrue(wide.contains("is-wide"), theme.id)
            XCTAssertFalse(wide.contains("<h1 class=\"page-title\">"), "\(theme.id) hides the title")
            let album = try render("/trip/", in: root)
            XCTAssertTrue(album.contains("<div class=\"album-grid\">") && album.contains("class=\"site-nav\""), theme.id)
        }
    }

    func testHomeStyleOptionStillWorks() throws {
        for theme in ThemeManifest.bundled() {
            let root = temp.appending(path: theme.id)
            try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: root)
            let values = theme.options.first { $0.key == "home_style" }?.values ?? []
            XCTAssertTrue(Set(values).isSuperset(of: ["list", "cards", "chain"]), theme.id)
            XCTAssertEqual(values.first, theme.defaults["home_style"].flatMap { if case let .text(s) = $0 { s } else { nil } }, theme.id)
            var config = ConfigDocument(text: try String(contentsOf: root.appending(path: "_config.yml"), encoding: .utf8))
            config.set("inkwell.home_style", raw: YAMLFormat.quoted("chain"))
            try config.text.write(to: root.appending(path: "_config.yml"), atomically: true, encoding: .utf8)
            XCTAssertTrue(try render("/", in: root).contains("post-list--chain"), theme.id)
        }
    }

    func testThemeTrialLeavesTheSiteAlone() throws {
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let site = temp.appending(path: "site")
        try FileManager.default.copyItem(at: fixtureSite(), to: site)
        try FileManager.default.createDirectory(at: site.appending(path: ".git"), withIntermediateDirectories: true)
        let before = try String(contentsOf: site.appending(path: "_config.yml"), encoding: .utf8)
        let theme = try XCTUnwrap(ThemeManifest.named("magazine"))
        let trial = temp.appending(path: "trial")
        try ThemeTrial.make(theme: theme, site: site, at: trial)
        XCTAssertEqual(try String(contentsOf: site.appending(path: "_config.yml"), encoding: .utf8), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: site.appending(path: "assets/css/inkwell.css").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trial.appending(path: "assets/css/inkwell.css").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.appending(path: ".git").path))
        XCTAssertThrowsError(try ThemeTrial.copySite(from: site, to: site))
        XCTAssertThrowsError(try ThemeTrial.copySite(from: site, to: site.appending(path: "inside")))
        XCTAssertThrowsError(try ThemeTrial.copySite(from: site, to: temp), "never clears a folder that holds the site")
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appending(path: "_config.yml").path))

        let pages = ThemeTrial.samplePages(in: try SiteLoader.load(ThemeManifest.sampleSite))
        XCTAssertEqual(pages.home, "/")
        XCTAssertEqual(pages.post, "/2026/10/the-long-way-round-the-headland/")
        XCTAssertEqual(pages.page, "/about/")
    }

    func testPalettesAndFontPairings() {
        for theme in ThemeManifest.bundled() {
            let palettes = DesignPresets.palettes(for: theme)
            XCTAssertGreaterThanOrEqual(palettes.count, 7, theme.id)
            XCTAssertEqual(palettes.first?.id, "original")
            XCTAssertEqual(Set(palettes.map(\.id)).count, palettes.count, "\(theme.id): ids are unique")
            for palette in palettes {
                XCTAssertEqual(Set(palette.light.keys), Set(DesignPresets.colorTokens), "\(theme.id)/\(palette.id)")
                XCTAssertEqual(Set(palette.dark.keys), Set(DesignPresets.colorTokens), "\(theme.id)/\(palette.id)")
            }
        }
        XCTAssertGreaterThanOrEqual(DesignPresets.fontPairings.count, 6)
        for pairing in DesignPresets.fontPairings {
            XCTAssertNotNil(DesignPresets.fontStack(matching: pairing.body.value))
            XCTAssertNotNil(DesignPresets.fontStack(matching: pairing.heading.value))
        }
        for theme in ThemeManifest.bundled() {
            for token in theme.tokens where token.kind == .font {
                XCTAssertNotNil(DesignPresets.fontStack(matching: token.light), "\(theme.id) \(token.name) has a name in the font menu")
            }
        }
    }

    func testApplyingAPresetSetsTheTokens() throws {
        let theme = try XCTUnwrap(ThemeManifest.named("essayist"))
        try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: temp)
        var tokens = try XCTUnwrap(DesignTokens.load(siteRoot: temp))
        let palettes = DesignPresets.palettes(for: theme)
        XCTAssertTrue(palettes[0].matches(tokens), "the theme's own colours are its first palette")
        let sepia = try XCTUnwrap(palettes.first { $0.id == "sepia" })
        XCTAssertFalse(sepia.matches(tokens))
        for name in DesignPresets.colorTokens {
            try tokens.set(name, to: sepia.light[name]!, scheme: .light, siteRoot: temp)
            try tokens.set(name, to: sepia.dark[name]!, scheme: .dark, siteRoot: temp)
        }
        tokens = try XCTUnwrap(DesignTokens.load(siteRoot: temp))
        XCTAssertTrue(sepia.matches(tokens))
        let pairing = try XCTUnwrap(DesignPresets.fontPairings.first { $0.id == "geometric" })
        XCTAssertFalse(pairing.matches(tokens))
        try tokens.set("--font-heading", to: pairing.heading.value, scheme: .light, siteRoot: temp)
        try tokens.set("--font-body", to: pairing.body.value, scheme: .light, siteRoot: temp)
        XCTAssertTrue(pairing.matches(try XCTUnwrap(DesignTokens.load(siteRoot: temp))))
    }
}
