import Foundation

/// A photo stream kept as one small file per photo in `_photos/`, listed by a Liquid loop on the photos page.
public enum PhotoStream {
    public static let collection = "photos"
    /// The album index, shown above the stream when the site has albums.
    public static let albumsInclude = "{% include inkwell/albums.html %}"

    public static let loop = """
    \(albumsInclude)

    <div class="photo-stream">
    {% assign photos = site.photos | where_exp: "photo", "photo.hidden != true" | sort: "date" | reverse %}
    {% for photo in photos %}
      <figure class="photo-item">
        <img src="{{ photo.image | relative_url }}" alt="{{ photo.alt | default: photo.caption | escape }}" loading="lazy">
        {% if photo.caption %}<figcaption class="photo-caption">{{ photo.caption }}</figcaption>{% endif %}
        {% if photo.location %}<p class="photo-location">{{ photo.location }}</p>{% endif %}
        <time datetime="{{ photo.date | date_to_xmlschema }}">{{ photo.date | date: "%b %-d, %Y" }}</time>
      </figure>
    {% endfor %}
    </div>
    """

    public struct Photo: Sendable, Equatable {
        public var image: String
        public var caption: String
        public var alt: String
        public var date: Date
        public var location: String
        public var albums: [String]

        public init(image: String, caption: String = "", alt: String = "", date: Date, location: String = "", albums: [String] = []) {
            self.image = image
            self.caption = caption
            self.alt = alt
            self.date = date
            self.location = location
            self.albums = albums
        }
    }

    public static func isSetUp(site: Site) -> Bool {
        site.config.collections.contains { $0.name == collection }
    }

    /// The photo's file: `_photos/YYYY-MM-DD-<slug>.md`, with only the fields that have values.
    public static func file(for photo: Photo, existing: Set<String>, timeZone: TimeZone) -> ContentEdit {
        let base = (photo.image as NSString).lastPathComponent
        let slug = Slug.make((base as NSString).deletingPathExtension, maxWords: 6)
        let date = YAMLFormat.date(photo.date, timeZone: timeZone)
        var name = "\(date)-\(slug).md"
        var n = 2
        while existing.contains("_photos/\(name)") {
            name = "\(date)-\(slug)-\(n).md"
            n += 1
        }
        var fields: [(String, String)] = [("image", photo.image)]
        if !photo.caption.isEmpty { fields.append(("caption", YAMLFormat.quoted(photo.caption))) }
        if !photo.alt.isEmpty { fields.append(("alt", YAMLFormat.quoted(photo.alt))) }
        fields.append(("date", date))
        if !photo.location.isEmpty { fields.append(("location", YAMLFormat.quoted(photo.location))) }
        if !photo.albums.isEmpty { fields.append(("albums", YAMLFormat.list(photo.albums))) }
        return ContentEdit(path: "_photos/\(name)", newText: FrontMatterDocument(fields: fields, body: "").text)
    }

    /// Changes that set up the photo stream: the collection in `_config.yml`, the photos page as a loop (keeping its
    /// front matter and introduction), files for any photos written by hand in the old page, and a menu entry if missing.
    public static func setupPlan(siteRoot: URL, timeZone: TimeZone) -> [(edit: ContentEdit, reason: String)] {
        func read(_ path: String) -> String? { try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8) }
        var plan: [(ContentEdit, String)] = []
        let configText = read("_config.yml") ?? ""
        var config = ConfigEditing(text: configText)
        if config.addCollection(collection, output: false) {
            let reason = localized("Adds a “photos” collection: one small file per photo in _photos/.")
            plan.append((ContentEdit(path: "_config.yml", newText: config.text), reason))
        }
        let pagePath = Self.pagePath(siteRoot: siteRoot) ?? "photos.md"
        let old = read(pagePath)
        var front = "---\nlayout: default\ntitle: Photos\n---\n\n"
        var intro = "# Photos\n\n"
        var migrated: [Photo] = []
        if let old {
            let doc = FrontMatterDocument(text: old)
            if doc.hasFrontMatter { front = String(old.dropLast(doc.body.count)) }
            let body = doc.body
            if body.contains("site.photos") {
                intro = ""
            } else if let start = body.range(of: "<div class=\"photo-stream\">") {
                intro = String(body[..<start.lowerBound])
                migrated = handWrittenPhotos(in: String(body[start.lowerBound...]), timeZone: timeZone)
            } else if !body.contains("site.photos") {
                intro = body.hasSuffix("\n\n") ? body : body + "\n\n"
            }
        }
        if old?.contains("site.photos") != true {
            plan.append((ContentEdit(path: pagePath, newText: front + intro + loop + "\n"),
                         old == nil ? localized("A photos page that shows the newest photos first.")
                             : localized("Shows the photos from _photos/ instead of hand-written HTML.")))
        }
        var taken = Set<String>()
        for photo in migrated {
            let edit = file(for: photo, existing: taken, timeZone: timeZone)
            taken.insert(edit.path)
            plan.append((edit, localized("Moves a photo that was written by hand in the old page.")))
        }
        let navText = read("_data/navigation.yml")
        // Only a plain list takes another item at its end; a file of named menus is left alone.
        let navigation = navText.map(YAML.parse)
        if let navText, navigation?.list != nil || navText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let listed = navigation?.list?.contains { $0["url"]?.string?.hasPrefix("/photos") == true } ?? false
            let urls = navigation?.list?.compactMap { $0["url"]?.string } ?? []
            let style = urls.first { $0.count > 1 && $0.hasPrefix("/") }?.hasSuffix("/") == true ? "/photos/" : "/photos"
            if !listed {
                let text = (navText.hasSuffix("\n") || navText.isEmpty ? navText : navText + "\n") + "- title: Photos\n  url: \(style)\n"
                plan.append((ContentEdit(path: "_data/navigation.yml", newText: text), localized("Adds Photos to the menu.")))
            }
        }
        return plan
    }

    /// The photos page, if the site has one.
    public static func pagePath(siteRoot: URL) -> String? {
        ["photos.md", "photos.html", "photos/index.md"].first { FileManager.default.fileExists(atPath: siteRoot.appending(path: $0).path) }
    }

    /// For a photos page set up before albums: the album index added above the stream. Nil when it is there already,
    /// or the page is not a photo stream.
    public static func albumsOnPhotosPage(siteRoot: URL) -> ContentEdit? {
        guard let path = pagePath(siteRoot: siteRoot), let text = try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8),
              text.contains("site.photos"), !text.contains("inkwell/albums.html") else { return nil }
        let anchor = text.range(of: "<div class=\"photo-stream\">") ?? text.range(of: "{% assign photos")
        guard let anchor else { return nil }
        let updated = String(text[..<anchor.lowerBound]) + albumsInclude + "\n\n" + String(text[anchor.lowerBound...])
        return ContentEdit(path: path, newText: updated)
    }

    /// `<div class="photo-item"><img src alt><p class="photo-caption">…</p><time>…</time></div>` blocks, as photos.
    static func handWrittenPhotos(in html: String, timeZone: TimeZone) -> [Photo] {
        let uncommented = html.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        guard let item = try? NSRegularExpression(pattern: #"(?s)<(div|figure)[^>]*class="photo-item"[^>]*>(.*?)</\1>"#) else { return [] }
        let ns = uncommented as NSString
        return item.matches(in: uncommented, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let inner = ns.substring(with: m.range(at: 2))
            guard let src = first(#"<img[^>]*src="([^"]+)""#, in: inner), !src.contains("{{") else { return nil }
            let caption = first(#"(?s)class="photo-caption"[^>]*>(.*?)</"#, in: inner) ?? ""
            let time = first(#"(?s)<time[^>]*>(.*?)</time>"#, in: inner)
            let date = time.flatMap { SiteDate.parse($0, timeZone: timeZone) ?? Self.looseDate($0, timeZone: timeZone) } ?? Date()
            return Photo(image: src, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                         alt: first(#"<img[^>]*alt="([^"]*)""#, in: inner) ?? "", date: date)
        }
    }

    static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    static func looseDate(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["MMM d, yyyy", "MMMM d, yyyy", "d MMMM yyyy", "d MMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        return nil
    }
}

public extension ConfigEditing {
    /// Adds `name:` under `collections:` (creating it) with `output:`; false when it is already there.
    @discardableResult
    mutating func addCollection(_ name: String, output: Bool) -> Bool {
        let parsed = YAML.parse(lines.joined(separator: "\n"))
        let collections = parsed["collections"]
        if collections?[name] != nil || collections?.list?.contains(where: { $0.string == name }) == true { return false }
        guard let start = lines.lastIndex(where: { $0.hasPrefix("collections:") }) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += ["collections:", "  \(name):", "    output: \(output)"]
            return true
        }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || line.hasPrefix(" ") || line.hasPrefix("-") else { break }
            end += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        // A list of names (`[notes, travel]` or `- notes` lines) becomes a mapping: the same collections, unchanged
        // (a listed collection has no pages of its own), and the new one.
        if let names = collections?.list?.compactMap(\.string) {
            var block = ["collections:"]
            for existing in names { block += ["  \(existing):", "    output: false"] }
            block += ["  \(name):", "    output: \(output)"]
            lines.replaceSubrange(start ..< end, with: block)
            return true
        }
        // The file's own indentation: its first child for the name, and that child's first setting below it.
        let body = lines[(start + 1) ..< end].filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        let childIndent = body.first.map { $0.prefix { $0 == " " }.count } ?? 2
        let grandchild = body.map { $0.prefix { $0 == " " }.count }.first { $0 > childIndent } ?? childIndent * 2
        lines.insert(contentsOf: [String(repeating: " ", count: childIndent) + "\(name):",
                                  String(repeating: " ", count: grandchild) + "output: \(output)"], at: end)
        return true
    }
}

/// Every image in the site and where each is used. "Unused" leads to deletion, so the matching leans towards "used":
/// a file referenced by its name anywhere (a relative path, a bare name in front matter, a srcset) counts as used.
public enum MediaLibrary {
    public struct Item: Sendable, Equatable, Identifiable {
        public var path: String
        public var bytes: Int
        public var usedBy: [String]
        /// Icons browsers ask for by name (favicon, apple-touch-icon…), which nothing has to link to.
        public var keptByConvention = false
        public var id: String { path }

        public var isUnused: Bool { usedBy.isEmpty && !keptByConvention }

        public init(path: String, bytes: Int, usedBy: [String], keptByConvention: Bool = false) {
            self.path = path
            self.bytes = bytes
            self.usedBy = usedBy
            self.keptByConvention = keptByConvention
        }
    }

    static let imageExtensions: Set = ["jpg", "jpeg", "png", "gif", "webp", "svg", "avif", "heic", "ico"]
    static let textExtensions: Set = ["md", "markdown", "html", "htm", "yml", "yaml", "css", "scss", "sass", "js", "mjs", "json", "xml",
                                      "liquid", "webmanifest", "txt", "toml"]
    static let conventionalIcons = ["favicon", "apple-touch-icon", "android-chrome", "mstile", "safari-pinned-tab"]

    /// `extraTexts` are files outside the site that can still use its images: local drafts, by a label and their text.
    public static func scan(siteRoot: URL, extraTexts: [(label: String, text: String)] = []) -> [Item] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: siteRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = siteRoot.standardizedFileURL.path
        var images: [(String, Int)] = []
        var texts: [(String, String)] = []
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if relative.hasPrefix("_site/") || relative.hasPrefix("node_modules/") || relative.hasPrefix("vendor/") {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                images.append((relative, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                // An SVG can draw other pictures.
                if ext == "svg", let text = try? String(contentsOf: url, encoding: .utf8) { texts.append((relative, text)) }
            } else if textExtensions.contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
                texts.append((relative, text))
            }
        }
        texts += extraTexts.map { ($0.label, $0.text) }
        let index = references(in: texts)
        return images.sorted { $0.0 < $1.0 }.map { path, bytes in
            let key = path.lowercased()
            let name = (key as NSString).lastPathComponent
            // The exact site path first; any file naming the picture otherwise, which also covers relative paths.
            var users = (index[key] ?? []).filter { $0 != path }
            if users.isEmpty { users = (index[name] ?? []).filter { $0 != path } }
            let conventional = conventionalIcons.contains { name.hasPrefix($0) }
            return Item(path: path, bytes: bytes, usedBy: Array(Set(users)).sorted(), keptByConvention: conventional)
        }
    }

    /// Every image-like reference in the texts, indexed (in lower case) under each of its trailing parts, split at `/`,
    /// spaces and `(`: "/assets/a/b@2x.png" under "assets/a/b@2x.png", "a/b@2x.png" and "b@2x.png".
    static func references(in texts: [(String, String)]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        // Each image extension, with the name before it back to a quote, tag, comma or line end: names may hold spaces,
        // @ and parentheses.
        let regex = try? NSRegularExpression(pattern: #"\.(?:jpe?g|png|gif|webp|svg|avif|heic|ico)(?![\p{L}\p{N}_-])"#,
                                             options: [.caseInsensitive])
        let stops = Set("\n\r\t\"'<>=[]{}|*,;:`".utf16)
        for (file, text) in texts {
            let ns = text as NSString
            var seen = Set<String>()
            for m in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                var start = m.range.location
                while start > 0, m.range.location - start < 300, !stops.contains(ns.character(at: start - 1)) { start -= 1 }
                guard start < m.range.location else { continue }
                let token = ns.substring(with: NSRange(location: start, length: NSMaxRange(m.range) - start))
                for form in Set([token, token.removingPercentEncoding ?? token]) {
                    let path = form.lowercased()
                    var start = path.startIndex
                    while true {
                        let suffix = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespaces))
                        if !suffix.isEmpty, seen.insert(suffix).inserted { index[suffix, default: []].append(file) }
                        guard let cut = path[start...].firstIndex(where: { $0 == "/" || $0 == " " || $0 == "(" }) else { break }
                        start = path.index(after: cut)
                    }
                }
            }
        }
        return index
    }
}
