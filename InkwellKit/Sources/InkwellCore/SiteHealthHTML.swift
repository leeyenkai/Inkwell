import Foundation

/// Checks for pages GitHub Pages serves as they are (SPEC §4.12): links and pictures that point at nothing, pictures
/// with no alt text, and pages without a title or description. These pages link relative to their own folder.
public extension SiteHealth {
    enum Reference: Equatable, Sendable {
        case link(String)
        case image(String)
        case resource(String)

        public var target: String {
            switch self {
            case let .link(t), let .image(t), let .resource(t): t
            }
        }
    }

    /// `href` and `src` values in the markup, outside scripts and comments.
    static func htmlReferences(in html: String) -> [Reference] {
        let markup = html
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)(<script\b[^>]*>).*?</script>"#, with: "$1</script>", options: .regularExpression)
        let ns = markup as NSString
        guard let tags = try? NSRegularExpression(pattern: #"<(a|img|link|script|source|video|audio|iframe)\b([^>]*)>"#, options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"\b(href|src|poster)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: .caseInsensitive)
        else { return [] }
        var result: [Reference] = []
        for tag in tags.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: tag.range(at: 1)).lowercased()
            let inside = tag.range(at: 2)
            if name == "link", ns.substring(with: inside).range(of: #"rel\s*=\s*["']?(preconnect|dns-prefetch|canonical|alternate)"#,
                                                                     options: [.regularExpression, .caseInsensitive]) != nil { continue }
            for m in attributes.matches(in: markup, range: inside) {
                let value = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))
                let decoded = HTMLHead.decode(value).trimmingCharacters(in: .whitespaces)
                switch name {
                case "a": result.append(.link(decoded))
                case "img": result.append(.image(decoded))
                default: result.append(.resource(decoded))
                }
            }
        }
        return result
    }

    /// The site path a reference leads to from a page, or nil for other sites, anchors, mail and script addresses.
    static func resolve(_ target: String, from pagePath: String, baseurl: String) -> String? {
        var path = target
        guard !path.isEmpty, !path.hasPrefix("#"), !path.hasPrefix("//"), !path.contains("{{"), !path.contains("{%") else { return nil }
        if let scheme = path.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression), !scheme.isEmpty { return nil }
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        var parts: [Substring]
        if path.hasPrefix("/") {
            if !baseurl.isEmpty, path.hasPrefix(baseurl + "/") || path == baseurl { path = String(path.dropFirst(baseurl.count)) }
            parts = []
        } else {
            parts = pagePath.split(separator: "/").dropLast()
        }
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            if piece == "." { continue }
            if piece == ".." {
                if parts.isEmpty { return nil }
                parts.removeLast()
            } else {
                parts.append(piece)
            }
        }
        let joined = parts.joined(separator: "/")
        return path.hasSuffix("/") && !joined.isEmpty ? joined + "/" : joined
    }

    internal static func staticPages(_ site: Site, texts: [String: String], files: FileIndex) -> [Issue] {
        var issues: [Issue] = []
        func exists(_ path: String) -> Bool {
            let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
            if folder.isEmpty { return files.exists("index.html") || files.exists("index.htm") }
            return files.exists(folder) || files.exists(folder + "/index.html") || files.exists(folder + "/index.htm")
                || files.exists(folder + ".html")
        }
        for doc in site.documents where doc.editsAsHTML {
            guard let text = texts[doc.relativePath] else { continue }
            var broken: [String] = [], missing: [String] = []
            for reference in htmlReferences(in: text) {
                guard let path = resolve(reference.target, from: doc.relativePath, baseurl: site.config.baseurl), !exists(path) else { continue }
                if case .image = reference {
                    if !missing.contains(reference.target) { missing.append(reference.target) }
                } else if !broken.contains(reference.target) {
                    broken.append(reference.target)
                }
            }
            if !broken.isEmpty {
                issues.append(Issue(id: "links:\(doc.relativePath)", category: .links, severity: .warning,
                                    title: localized("\(broken.count) links in “\(doc.title)” go nowhere"),
                                    detail: broken.joined(separator: "\n"), paths: [doc.relativePath], fix: nil))
            }
            if !missing.isEmpty {
                issues.append(Issue(id: "images:\(doc.relativePath)", category: .links, severity: .error,
                                    title: localized("\(missing.count) images in “\(doc.title)” are missing"),
                                    detail: missing.joined(separator: "\n"), paths: [doc.relativePath], fix: nil))
            }
            let noAlt = imagesWithoutAlt(in: text)
            if !noAlt.isEmpty {
                issues.append(Issue(id: "alt:\(doc.relativePath)", category: .media, severity: .warning,
                                    title: localized("\(noAlt.count) images in “\(doc.title)” have no alt text"),
                                    detail: localized("Screen readers say nothing useful for them. Decorative pictures can have an empty alt.") + " "
                                        + noAlt.joined(separator: ", "),
                                    paths: [doc.relativePath], fix: nil))
            }
        }
        if site.kind.servesFilesAsIs {
            let pages = site.documents.filter { $0.isStatic && $0.relativePath != "404.html" }
            let heads = pages.compactMap { doc in texts[doc.relativePath].map { (doc, HTMLHead($0)) } }
            let untitled = heads.filter { ($0.1.title ?? "").isEmpty }.map(\.0.relativePath)
            if !untitled.isEmpty {
                issues.append(Issue(id: "html-title", category: .sharing, severity: .warning,
                                    title: localized("\(untitled.count) pages have no title"),
                                    detail: localized("Browsers and search results show the address instead.") + "\n" + untitled.joined(separator: "\n"),
                                    paths: untitled, fix: nil))
            }
            let undescribed = heads.filter { ($0.1.description ?? "").isEmpty }.map(\.0.relativePath)
            if !undescribed.isEmpty {
                issues.append(Issue(id: "html-description", category: .sharing, severity: .info,
                                    title: localized("\(undescribed.count) pages have no description"),
                                    detail: localized("Search results and shared links show a summary from it.") + "\n" + undescribed.joined(separator: "\n"),
                                    paths: undescribed, fix: nil))
            }
            if let home = heads.first(where: { $0.0.relativePath == "index.html" }), (home.1.image ?? "").isEmpty {
                issues.append(Issue(id: "html-share-image", category: .sharing, severity: .info, title: localized("No share image"),
                                    detail: localized("Links to your site show this picture when no post has its own."),
                                    paths: ["index.html"], fix: nil))
            }
        }
        return issues
    }

    /// The `src` of each `<img>` with no `alt` attribute at all. An empty `alt` marks a decorative picture and is fine.
    static func imagesWithoutAlt(in html: String) -> [String] {
        let markup = html.replacingOccurrences(of: #"(?is)(<script\b[^>]*>).*?</script>"#, with: "$1</script>", options: .regularExpression)
        let ns = markup as NSString
        guard let regex = try? NSRegularExpression(pattern: #"<img\b([^>]*)>"#, options: .caseInsensitive) else { return [] }
        return regex.matches(in: markup, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let attributes = ns.substring(with: m.range(at: 1))
            guard attributes.range(of: #"\balt\s*="#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            let src = attributes.range(of: #"src\s*=\s*["'][^"']*"#, options: [.regularExpression, .caseInsensitive])
                .map { String(attributes[$0]).replacingOccurrences(of: #"src\s*=\s*["']"#, with: "", options: .regularExpression) }
            return src ?? "img"
        }
    }
}
