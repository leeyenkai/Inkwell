import Foundation
import InkwellCore

/// The site files page elements need: includes under `_includes/inkwell/`, a stylesheet and a small script.
/// Elements are HTML with Markdown inside (kramdown's `markdown="1"`), so pages stay readable without Inkwell.
public enum ElementKit {
    public static let stylesheet = "assets/css/inkwell-blocks.css"
    public static let script = "assets/js/inkwell-blocks.js"
    /// For themes Inkwell did not write: the two tags that load the kit, added before `</head>`.
    public static let headTags = """
    <link rel="stylesheet" href="{{ '/assets/css/inkwell-blocks.css' | relative_url }}">
    <script src="{{ '/assets/js/inkwell-blocks.js' | relative_url }}" defer></script>
    """

    static var folder: URL { Bundle.module.resourceURL!.appending(path: "ElementKit", directoryHint: .isDirectory) }

    public static var files: [String: String] { BundledFiles.read(folder) }

    /// Kit files that are missing or older than this version of Inkwell.
    public static func changes(siteRoot: URL) -> [FileChange] {
        files.sorted { $0.key < $1.key }.compactMap { path, text in
            let old = try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8)
            guard old != text else { return nil }
            return FileChange(path: path, oldText: old, newText: text, reason: localized("Used by page elements such as galleries, maps and timelines."))
        }
    }

    /// Whether the site's pages load the kit: an Inkwell theme does; another theme needs the head tags.
    public static func isLoaded(siteRoot: URL) -> Bool {
        let fm = FileManager.default
        var candidates = ["_includes/head.html", "_includes/head-custom.html", "_layouts/default.html"]
        for folder in ["_layouts", "_includes"] {
            candidates += ((try? fm.contentsOfDirectory(atPath: siteRoot.appending(path: folder).path)) ?? []).map { "\(folder)/\($0)" }
        }
        return candidates.contains { path in
            (try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8))?.contains("inkwell-blocks.css") == true
        }
    }
}
