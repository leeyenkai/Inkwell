import Foundation
@testable import InkwellCore
@testable import InkwellDesign
import XCTest

/// The string catalogs are the source of the English text too: counted messages need their singular form there.
final class LocalizationTests: XCTestCase {
    static var sources: URL { URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardizedFileURL }

    func catalogs() throws -> [URL] {
        let folders = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
        let catalogs = folders.map { $0.appending(path: "Localizable.xcstrings") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertGreaterThanOrEqual(catalogs.count, 6)
        return catalogs
    }

    func testCountedStringsHavePluralForms() throws {
        let appCatalog = Self.sources.appending(path: "../../Inkwell/Resources/Localizable.xcstrings").standardizedFileURL
        for url in try catalogs() + [appCatalog] where FileManager.default.fileExists(atPath: url.path) {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
            for (key, entry) in strings where key.range(of: #"%(\d\$)?lld"#, options: .regularExpression) != nil {
                // Automatic grammar agreement (`^[…](inflect: true)`) needs no plural forms of its own.
                guard entry["extractionState"] as? String != "stale", entry["shouldTranslate"] as? Bool != false,
                      !key.contains("(inflect: true)") else { continue }
                let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
                XCTAssertNotNil(english?["variations"] ?? english?["substitutions"], "\(url.lastPathComponent): no plural forms for “\(key)”")
            }
        }
    }

    func testEnglishPlurals() {
        XCTAssertEqual(InkwellCore.localized("\(1) images are over 1 MB"), "1 image is over 1 MB")
        XCTAssertEqual(InkwellCore.localized("\(3) images are over 1 MB"), "3 images are over 1 MB")
        XCTAssertEqual(InkwellCore.localized("\(1) links in “\("A")” go nowhere"), "1 link in “A” goes nowhere")
    }

    func testThemeLabelsComeFromTheThemesTable() throws {
        let theme = try XCTUnwrap(ThemeManifest.named("essayist"))
        XCTAssertEqual(theme.tokens.first?.group, "Colours")
        XCTAssertEqual(theme.options.first?.label, "Home page list")
    }
}
