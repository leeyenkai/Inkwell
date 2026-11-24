import Foundation

/// A photo album: an entry in `_data/albums.yml` and a page at `albums/<id>.md`. Photos join it through `albums:` in their
/// own front matter, so the album page is a Liquid loop that GitHub Pages builds without plugins.
public struct Album: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    /// An image path such as `/assets/photos/2025/kyoto.jpg`; empty means the newest photo in the album.
    public var cover: String
    public var date: String
    /// The album page lists photos oldest first (a trip, in the order it happened) instead of newest first.
    public var oldestFirst: Bool

    public init(id: String, title: String, description: String = "", cover: String = "", date: String = "", oldestFirst: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.cover = cover
        self.date = date
        self.oldestFirst = oldestFirst
    }

    init(_ value: YAMLValue) {
        id = value["id"]?.string ?? ""
        title = value["title"]?.string ?? id
        description = value["description"]?.string ?? ""
        cover = value["cover"]?.string ?? ""
        date = value["date"]?.string ?? ""
        oldestFirst = value["order"]?.string == "oldest"
    }

    public var pagePath: String { Albums.pagePath(id) }
    public var url: String { Albums.url(id) }
}

public enum Albums {
    public static let dataPath = "_data/albums.yml"
    public static let folder = "albums"
    /// The site files albums need, all part of the element kit.
    public static let kitFiles = ["_layouts/album.html", "_includes/inkwell/album.html", "_includes/inkwell/albums.html"]
    /// The order photo fields are written in, so `albums:` lands next to the other descriptive fields.
    static let photoFieldOrder = ["image", "caption", "alt", "date", "location", "albums", "hidden"]

    public static func pagePath(_ id: String) -> String { "\(folder)/\(id).md" }
    public static func url(_ id: String) -> String { "/\(folder)/\(id)/" }

    /// The include that shows an album inside any post or page.
    public static func include(_ id: String, style: String? = nil) -> String {
        let style = style.map { " style=\"\($0)\"" } ?? ""
        return "{% include inkwell/album.html album=\"\(id)\"\(style) %}"
    }

    /// The albums a photo belongs to: its `albums:` list (or a single value there), then a single `album:`.
    public static func ids(in values: YAMLValue) -> [String] {
        var ids: [String] = []
        switch values["albums"] {
        case let .list(items)?: ids = items.compactMap(\.string)
        case let value?: if let one = value.string { ids = [one] }
        case nil: break
        }
        if let single = values["album"]?.string, !ids.contains(single) { ids.append(single) }
        return ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A new album id from its title: a slug that is not all digits and not taken.
    public static func newID(for title: String, taken: Set<String>) -> String {
        var base = Slug.make(title, maxWords: 6)
        if base == "untitled" { base = "album" }
        if base.allSatisfy(\.isNumber) { base = "album-\(base)" }
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    static func pageText(id: String, title: String) -> String {
        FrontMatterDocument(fields: [("layout", "album"), ("title", YAMLFormat.quoted(title)), ("album", id),
                                     ("permalink", url(id))], body: "").text
    }

    /// The head file with the kit's tags just before `</head>`, for a site whose own layouts do not load the kit yet.
    /// Nil when the site's head comes from a theme it does not hold, or already has the tags.
    public static func headTagsEdit(siteRoot: URL, tags: String) -> ContentEdit? {
        let head = SiteHealth.HeadFiles(root: siteRoot)
        guard let file = head.file, !head.original.contains("inkwell-blocks.css"),
              let close = head.original.range(of: "</head>", options: [.caseInsensitive, .backwards]) else { return nil }
        let original = head.original
        let lineStart = original[..<close.lowerBound].lastIndex(of: "\n").map { original.index(after: $0) } ?? original.startIndex
        let closeIndent = String(original[lineStart ..< close.lowerBound].prefix { $0 == " " || $0 == "\t" })
        let above = original[..<lineStart].split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let aboveIndent = String(above.prefix { $0 == " " || $0 == "\t" })
        let inner = aboveIndent.count > closeIndent.count && !above.lowercased().contains("<head") ? aboveIndent : closeIndent + "  "
        let lines = tags.split(separator: "\n").map { inner + $0 + "\n" }.joined()
        return ContentEdit(path: file, newText: String(original[..<lineStart]) + lines + String(original[lineStart...]))
    }
}

/// `_data/albums.yml` kept as lines. Each album is a block starting with `- ` at the left edge, so changing a field
/// rewrites that field's line, reordering moves whole blocks, and comments and spacing elsewhere stay as written.
public struct AlbumsFile: Sendable, Equatable {
    var header: [String] = []
    var blocks: [[String]] = []
    var endsWithNewline = true

    public init(text: String?) {
        guard let text, !text.isEmpty else { return }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        } else {
            endsWithNewline = false
        }
        for line in lines {
            if line == "-" || line.hasPrefix("- ") {
                blocks.append([line])
            } else if blocks.isEmpty {
                header.append(line)
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
    }

    public var text: String {
        let lines = header + blocks.flatMap { $0 }
        return lines.joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "")
    }

    /// True when nothing but blank lines would be left.
    var isBlank: Bool { blocks.isEmpty && header.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    public var albums: [Album] { blocks.map { Album(Self.value(of: $0)) } }

    static func value(of block: [String]) -> YAMLValue {
        YAML.parse(block.joined(separator: "\n")).list?.first ?? .map([])
    }

    func index(of id: String) -> Int? {
        blocks.firstIndex { Self.value(of: $0)["id"]?.string == id }
    }

    // MARK: Fields

    /// The column the block's fields start at: two for `- id: x`.
    static func fieldIndent(_ block: [String]) -> Int {
        let first = block[0]
        if first.count > 1 {
            let afterDash = first.dropFirst()
            let spaces = afterDash.prefix { $0 == " " }.count
            if afterDash.count > spaces { return 1 + spaces }
        }
        return block.dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count } ?? 2
    }

    /// Each field's key and line range in the block (a field's range ends at its last line with content).
    static func spans(_ block: [String]) -> [(key: String, range: Range<Int>)] {
        let indent = fieldIndent(block)
        var spans: [(key: String, range: Range<Int>)] = []
        var lastContent = 0
        for (i, line) in block.enumerated() {
            let content: Substring
            let lineIndent: Int
            if i == 0 {
                lineIndent = indent
                content = line.count > indent ? line.dropFirst(indent) : ""
            } else {
                lineIndent = line.prefix { $0 == " " }.count
                content = line.dropFirst(lineIndent)
            }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if lineIndent == indent, let (key, _) = YAML.splitKey(String(content)) {
                if !spans.isEmpty { spans[spans.count - 1].range = spans[spans.count - 1].range.lowerBound ..< lastContent + 1 }
                spans.append((key, i ..< i + 1))
            }
            lastContent = i
        }
        if !spans.isEmpty { spans[spans.count - 1].range = spans[spans.count - 1].range.lowerBound ..< lastContent + 1 }
        return spans
    }

    /// Sets a field of one album to an already-formatted YAML value, or removes it when `raw` is nil.
    /// Leaves the block untouched when the field already holds the same value.
    mutating func set(_ key: String, raw: String?, at index: Int) {
        var block = blocks[index]
        let indent = Self.fieldIndent(block)
        let pad = String(repeating: " ", count: indent)
        let spans = Self.spans(block)
        if let span = spans.first(where: { $0.key == key }) {
            let firstLine = span.range.lowerBound == 0
            if let raw {
                let current = Self.value(of: block)[key]
                let proposed = YAML.parse("\(key): \(raw)")[key]
                if current == proposed, span.range.count == 1 { return }
                let prefix = firstLine ? "-" + String(repeating: " ", count: indent - 1) : pad
                block.replaceSubrange(span.range, with: [prefix + "\(key): \(raw)"])
            } else {
                block.removeSubrange(span.range)
                if firstLine {
                    // The next field moves up to carry the dash.
                    let next = block.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
                    if block.isEmpty {
                        block = ["-"]
                    } else {
                        let rest = block[next].dropFirst(min(indent, block[next].count))
                        block[next] = "-" + String(repeating: " ", count: indent - 1) + rest
                        if next > 0 { block.removeSubrange(0 ..< next) }
                    }
                }
            }
        } else {
            guard let raw else { return }
            let insertAt = spans.last?.range.upperBound ?? 1
            block.insert(pad + "\(key): \(raw)", at: min(insertAt, block.count))
        }
        blocks[index] = block
    }

    // MARK: Albums

    mutating func append(_ album: Album) {
        // Albums separated by blank lines keep that spacing.
        let blank = { (line: String?) in line?.trimmingCharacters(in: .whitespaces).isEmpty == true }
        if let last = blocks.indices.last, blocks.count > 1, blank(blocks[blocks.count - 2].last), !blank(blocks[last].last) {
            blocks[last].append("")
        }
        var block = ["- id: \(YAMLFormat.plainOrQuoted(album.id))", "  title: \(YAMLFormat.quoted(album.title))"]
        if !album.description.isEmpty { block.append("  description: \(YAMLFormat.quoted(album.description))") }
        if !album.cover.isEmpty { block.append("  cover: \(album.cover)") }
        if !album.date.isEmpty { block.append("  date: \(album.date)") }
        if album.oldestFirst { block.append("  order: oldest") }
        blocks.append(block)
    }

    mutating func remove(at index: Int) {
        let removed = blocks.remove(at: index)
        // A blank line that separated the last album from the removed one goes with it.
        if index == blocks.count, index > 0, removed.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
            while blocks[index - 1].count > 1, blocks[index - 1].last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                blocks[index - 1].removeLast()
            }
        }
    }

    /// Puts the albums in the order of `ids`; albums not named keep their order after them.
    mutating func reorder(_ ids: [String]) {
        let keyed = blocks.map { (Self.value(of: $0)["id"]?.string ?? "", $0) }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var sorted = keyed.enumerated().sorted { a, b in
            (rank[a.element.0] ?? ids.count + a.offset, a.offset) < (rank[b.element.0] ?? ids.count + b.offset, b.offset)
        }.map(\.element.1)
        // Blank lines between albums stay between albums: none trails the new last block unless one trailed the old.
        let trailingBlank = { (block: [String]) in block.count > 1 && block.last?.trimmingCharacters(in: .whitespaces).isEmpty == true }
        let separated = blocks.dropLast().contains(where: trailingBlank)
        let endedBlank = blocks.last.map(trailingBlank) ?? false
        if separated {
            for i in sorted.indices {
                let isLast = i == sorted.count - 1
                while trailingBlank(sorted[i]) { sorted[i].removeLast() }
                if !isLast || endedBlank { sorted[i].append("") }
            }
        }
        blocks = sorted
    }
}

/// The albums and the photo files that join them, read once and changed in memory. Every change returns the edits that
/// write it; changes made one after another give edits whose texts already include the earlier ones.
public struct AlbumLibrary: Sendable {
    public struct PhotoFile: Sendable, Equatable {
        public var path: String
        public var text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }

        public var albumIDs: [String] { Albums.ids(in: FrontMatterDocument(text: text).values) }
    }

    public private(set) var file: AlbumsFile
    public private(set) var fileExists: Bool
    public private(set) var photos: [PhotoFile]
    /// Album pages by path, `albums/<id>.md`.
    public private(set) var pages: [String: String]

    public init(albumsText: String?, photos: [PhotoFile], pages: [String: String] = [:]) {
        file = AlbumsFile(text: albumsText)
        fileExists = albumsText != nil
        self.photos = photos
        self.pages = pages
    }

    public static func load(siteRoot: URL) -> AlbumLibrary {
        let fm = FileManager.default
        func read(_ path: String) -> String? { try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8) }
        func files(in folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: siteRoot.appending(path: folder).path)) ?? [])
                .filter { $0.hasSuffix(".md") || $0.hasSuffix(".markdown") || $0.hasSuffix(".html") }.sorted().map { "\(folder)/\($0)" }
        }
        let photos = files(in: "_\(PhotoStream.collection)").compactMap { path in read(path).map { PhotoFile(path: path, text: $0) } }
        var pages: [String: String] = [:]
        for path in files(in: Albums.folder) { pages[path] = read(path) }
        return AlbumLibrary(albumsText: read(Albums.dataPath), photos: photos, pages: pages)
    }

    public var albums: [Album] { file.albums }

    public func album(_ id: String) -> Album? { albums.first { $0.id == id } }

    /// Paths of the photos in an album, in file order.
    public func photoPaths(in id: String) -> [String] { photos.filter { $0.albumIDs.contains(id) }.map(\.path) }

    /// Paths of the photos in no album.
    public var photoPathsWithoutAlbum: [String] { photos.filter(\.albumIDs.isEmpty).map(\.path) }

    var dataEdit: ContentEdit { ContentEdit(path: Albums.dataPath, newText: file.text) }

    // MARK: Albums

    /// A new album at the end of the list, with its page. The id comes from the title and never changes.
    public mutating func create(title: String, description: String = "") -> (id: String, edits: [ContentEdit]) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(albums.map(\.id)).union(pages.keys.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        let id = Albums.newID(for: clean, taken: taken)
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        file.append(Album(id: id, title: clean.isEmpty ? id : clean, description: about))
        fileExists = true
        let page = Albums.pageText(id: id, title: clean.isEmpty ? id : clean)
        pages[Albums.pagePath(id)] = page
        return (id, [dataEdit, ContentEdit(path: Albums.pagePath(id), newText: page)])
    }

    /// A new title in the list and on the album's page; the id and the address stay.
    public mutating func rename(_ id: String, to title: String) -> [ContentEdit] {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = file.index(of: id) else { return [] }
        let before = file
        file.set("title", raw: YAMLFormat.quoted(clean), at: index)
        var edits = file == before ? [] : [dataEdit]
        let path = Albums.pagePath(id)
        if let text = pages[path] {
            var doc = FrontMatterDocument(text: text)
            doc.set("title", raw: YAMLFormat.quoted(clean), order: ["layout", "title"])
            if doc.text != text {
                pages[path] = doc.text
                edits.append(ContentEdit(path: path, newText: doc.text))
            }
        }
        return edits
    }

    public mutating func setDescription(_ id: String, to text: String) -> [ContentEdit] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return setField("description", raw: clean.isEmpty ? nil : YAMLFormat.quoted(clean), album: id)
    }

    /// The album's cover image, or nil for the newest photo in it.
    public mutating func setCover(_ id: String, image: String?) -> [ContentEdit] {
        setField("cover", raw: image.flatMap { $0.isEmpty ? nil : YAMLFormat.plainOrQuoted($0) }, album: id)
    }

    public mutating func setOldestFirst(_ id: String, _ oldestFirst: Bool) -> [ContentEdit] {
        setField("order", raw: oldestFirst ? "oldest" : nil, album: id)
    }

    mutating func setField(_ key: String, raw: String?, album id: String) -> [ContentEdit] {
        guard let index = file.index(of: id) else { return [] }
        let before = file
        file.set(key, raw: raw, at: index)
        return file == before ? [] : [dataEdit]
    }

    /// Removes the album and its page, and the album from its photos. The photos themselves stay.
    public mutating func delete(_ id: String) -> [ContentEdit] {
        var edits: [ContentEdit] = []
        if let index = file.index(of: id) {
            file.remove(at: index)
            edits.append(file.isBlank ? ContentEdit(path: Albums.dataPath, newText: nil) : dataEdit)
            if file.isBlank { fileExists = false }
        }
        let page = Albums.pagePath(id)
        if pages.removeValue(forKey: page) != nil { edits.append(ContentEdit(path: page, newText: nil)) }
        return edits + remove(photoPaths(in: id), from: id)
    }

    /// Puts the albums in this order, which is the order the site shows them in.
    public mutating func reorder(_ ids: [String]) -> [ContentEdit] {
        let before = file
        file.reorder(ids)
        return file == before ? [] : [dataEdit]
    }

    // MARK: Photos

    public mutating func add(_ paths: [String], to id: String) -> [ContentEdit] {
        editPhotos(paths) { doc in
            let ids = Albums.ids(in: doc.values)
            guard !ids.contains(id) else { return }
            doc.set("albums", raw: YAMLFormat.list(Self.listed(doc) + [id]), order: Albums.photoFieldOrder)
        }
    }

    public mutating func remove(_ paths: [String], from id: String) -> [ContentEdit] {
        editPhotos(paths) { doc in
            let listed = Self.listed(doc)
            if listed.contains(id) {
                let rest = listed.filter { $0 != id }
                doc.set("albums", raw: rest.isEmpty ? nil : YAMLFormat.list(rest), order: Albums.photoFieldOrder)
            }
            if doc.value("album")?.string == id { doc.set("album", raw: nil) }
        }
    }

    /// The ids written in `albums:` itself.
    static func listed(_ doc: FrontMatterDocument) -> [String] {
        switch doc.value("albums") {
        case let .list(items)?: items.compactMap(\.string)
        case let value?: value.string.map { [$0] } ?? []
        case nil: []
        }
    }

    mutating func editPhotos(_ paths: [String], _ change: (inout FrontMatterDocument) -> Void) -> [ContentEdit] {
        var edits: [ContentEdit] = []
        for path in Set(paths).sorted() {
            guard let i = photos.firstIndex(where: { $0.path == path }) else { continue }
            var doc = FrontMatterDocument(text: photos[i].text)
            change(&doc)
            guard doc.text != photos[i].text else { continue }
            photos[i].text = doc.text
            edits.append(ContentEdit(path: path, newText: doc.text))
        }
        return edits
    }
}

extension [ContentEdit] {
    /// One edit per path, the last one winning, in the order paths were first changed.
    public var merged: [ContentEdit] {
        var order: [String] = []
        var latest: [String: ContentEdit] = [:]
        for edit in self {
            if latest[edit.path] == nil { order.append(edit.path) }
            latest[edit.path] = edit
        }
        return order.compactMap { latest[$0] }
    }
}
