import CryptoKit
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

    /// Kit files that are missing, or that Inkwell wrote in an older version. A file at a kit path that matches no version
    /// Inkwell shipped is the site's own (its own layout of the same name, or a kit file someone edited) and stays as it is.
    public static func changes(siteRoot: URL) -> [FileChange] {
        files.sorted { $0.key < $1.key }.compactMap { path, text in
            let old = try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8)
            guard old != text, old.map(isShipped) ?? true else { return nil }
            return FileChange(path: path, oldText: old, newText: text, reason: localized("Used by page elements such as galleries, maps and timelines."))
        }
    }

    /// Whether `text` is a kit file exactly as some version of Inkwell wrote it.
    public static func isShipped(_ text: String) -> Bool { shippedVersions.contains(digest(text)) }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of every version of every kit file Inkwell has shipped, the current ones included. When a kit file changes,
    /// add the new digest here (`ElementKitTests` prints it); keep the old ones, so sites with them still get updates.
    static let shippedVersions: Set<String> = [
        // assets/css/inkwell-blocks.css
        "e6ea14370fee82ddde78810bad146851a0fb0595e8e6e9e4d5c9575c26e2fb00",
        "6981bd2bfb7555df52eef40aa8b174ffa6954c88ddc214c68724a3acaaec50db",
        "1e29b55e5ece306899d5d70eded3b1c3742e7ad7fd4c97c0f30162c676260cd1",
        "a9da91dda4ee82aa4e10cbd46fdead277c8194a24fbfe11abdff4158b387fe4d",
        "6abe9517d025aee576b2ab0d1746eed425c7f399168c67b0ecd2b0197ddd6965",
        // assets/js/inkwell-blocks.js
        "1a12ed4b18a774303be0371ec18d3ec49f9cc6e6d60b633db28c9f534ccdcafa",
        "4bad831c90eb83b4537b60a8f993bbaab91b24d8cea251cedfca3dc63a9cfd64",
        "be268571ccdc9c056685ad5387ea9cbcc55f5f3e870061f986dd1c5d3010a0c5",
        "4e4ba459b3678ee650f44162a63a2da8ac0c76325cc8984d2b887aac4fcd75e0",
        "32a52481deff2244c451bd04eaa96bd3d39a812e2a9ae024988f3df0b03e496a",
        // _includes/inkwell/album.html, albums.html, archive.html, recent.html
        "25f6582734498b86cfd8c132b2871ea668c88760e5018ec35c35a0a3f55fb51f",
        "8e13acd0b5bc68afc87ec7a604fda9da95d0b7ff2353743e96c5eddadc7c75bb",
        "e36c370c44366789ae70314b83f02ca49d75d25175816622923bc770b6cba341",
        "ceb8f53370eaeb20f8e09cbe13ee06eb57adbda3c74d17167cd3e6e16826db88",
        "5d16189a6b28c1bd9cd02b6e7a46bf117d5be4cb6e339fe2c4e28bc6c2d57f74",
        "4063c1932c8732af31d63688b3c00d795fc32dfa75a93759660e891dad62aa67",
        // _layouts/album.html, inkwell-slides.html
        "8681f6be77e9d6477939c676042e9b92531a255977583c8ac8897ae1592a0e15",
        "eef911478cd7c727fe6cc2577d8aebb68209840a71cba7a64c994ea45908992c",
    ]

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
