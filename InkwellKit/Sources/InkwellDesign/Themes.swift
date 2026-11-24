import Foundation
import InkwellCore

public enum OptionValue: Codable, Sendable, Equatable {
    case text(String)
    case flag(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .flag(b) } else { self = try .text(c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .text(s): try c.encode(s)
        case let .flag(b): try c.encode(b)
        }
    }

    public var yaml: String {
        switch self {
        case let .text(s): YAMLFormat.quoted(s)
        case let .flag(b): YAMLFormat.bool(b)
        }
    }
}

/// A bundled theme: shared layouts plus this theme's tokens (light and dark values) and option defaults.
public struct ThemeManifest: Decodable, Sendable, Identifiable, Equatable {
    public struct TokenSpec: Decodable, Sendable, Equatable {
        public var name: String
        public var label: String
        public var kind: TokenKind
        public var group: String
        public var light: String
        public var dark: String?
    }

    public struct OptionSpec: Decodable, Sendable, Equatable {
        public var key: String
        public var label: String
        public var kind: String
        public var values: [String]?
    }

    public var id: String
    public var name: String
    public var summary: String
    public var tokens: [TokenSpec]
    public var options: [OptionSpec]
    public var defaults: [String: OptionValue]

    static var themesFolder: URL { Bundle.module.resourceURL!.appending(path: "Themes", directoryHint: .isDirectory) }
    static var baseFolder: URL { themesFolder.appending(path: "_base", directoryHint: .isDirectory) }

    public static func bundled() -> [ThemeManifest] {
        let order = ["essayist", "notebook", "photo-journal", "minimal"]
        let folders = (try? FileManager.default.contentsOfDirectory(at: themesFolder, includingPropertiesForKeys: nil)) ?? []
        let themes = folders.compactMap { folder -> ThemeManifest? in
            guard let data = try? Data(contentsOf: folder.appending(path: "theme.json")) else { return nil }
            return try? JSONDecoder().decode(ThemeManifest.self, from: data)
        }
        return themes.sorted { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
    }

    public static func named(_ id: String) -> ThemeManifest? { bundled().first { $0.id == id } }

    func tokenBlock(_ scheme: ColorSchemeKind) -> String {
        var out = ":root {\n"
        for token in tokens {
            guard let value = scheme == .light ? token.light : token.dark else { continue }
            out += "    \(token.name): \(value);\n"
        }
        return out + "}\n"
    }

    var stylesheet: String {
        let base = (try? String(contentsOf: Self.baseFolder.appending(path: "assets/css/inkwell-base.css"), encoding: .utf8)) ?? ""
        return "/* \(name) theme tokens. */\n" + tokenBlock(.light) + "\n" + base
    }

    var darkStylesheet: String {
        "/* \(name) theme, dark palette. Loaded when the reader's system is in dark mode. */\n" + tokenBlock(.dark)
    }
}

/// One file a design change would write, with what it replaces, so it can be shown before it is applied.
public struct FileChange: Sendable, Equatable, Identifiable {
    public var path: String
    public var oldText: String?
    public var newText: String?
    public var reason: String
    public var id: String { path }

    public var kind: String {
        switch (oldText, newText) {
        case (nil, _): "Add"
        case (_, nil): "Remove"
        default: "Change"
        }
    }
}

public struct AdoptionPlan: Sendable, Equatable {
    public var title: String
    public var changes: [FileChange]

    public func apply(to root: URL) throws {
        let fm = FileManager.default
        for change in changes {
            let url = root.appending(path: change.path)
            if let text = change.newText {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }
}

public enum ThemeApplier {
    /// The changes that switch a site to a bundled theme. Posts and pages are never touched; layouts with the same
    /// names are replaced, the theme's stylesheets are added, and `_config.yml` gets an `inkwell:` section.
    public static func plan(theme: ThemeManifest, siteRoot: URL) -> AdoptionPlan {
        var changes: [FileChange] = []
        func propose(_ path: String, _ text: String?, _ reason: String) {
            let old = try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8)
            guard old != text else { return }
            changes.append(FileChange(path: path, oldText: old, newText: text, reason: reason))
        }
        let base = ThemeManifest.baseFolder
        let reasons = [
            "_layouts/default.html": "The page frame: header, navigation and footer.",
            "_layouts/post.html": "How a post looks: title, byline, date and text.",
            "_layouts/page.html": "How a standalone page looks.",
            "_layouts/home.html": "A home page that lists your latest posts.",
            "_includes/inkwell-header.html": "The site title and navigation.",
            "_includes/inkwell-footer.html": "The footer line.",
            "_includes/inkwell-post-list.html": "The list of posts used on the home page.",
        ]
        for (path, reason) in reasons.sorted(by: { $0.key < $1.key }) {
            propose(path, try? String(contentsOf: base.appending(path: path), encoding: .utf8), reason)
        }
        propose("assets/css/inkwell.css", theme.stylesheet, "The \(theme.name) colours, fonts and styles.")
        propose("assets/css/inkwell-dark.css", theme.darkStylesheet, "The dark palette, used when the reader’s Mac or phone is in dark mode.")

        let configURL = siteRoot.appending(path: "_config.yml")
        let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var config = ConfigDocument(text: configText)
        config.set("inkwell.theme", raw: YAMLFormat.quoted(theme.id))
        for (key, value) in theme.defaults.sorted(by: { $0.key < $1.key }) where config.value("inkwell.\(key)") == nil {
            config.set("inkwell.\(key)", raw: value.yaml)
        }
        if config.value("inkwell.home_collection") == nil {
            config.set("inkwell.home_collection", raw: YAMLFormat.quoted(homeCollection(siteRoot: siteRoot, config: config)))
        }
        propose("_config.yml", config.text, "Remembers the theme and its options under “inkwell:”.")

        if !FileManager.default.fileExists(atPath: siteRoot.appending(path: "_data/navigation.yml").path) {
            propose("_data/navigation.yml", NavigationDocument(entries: suggestedNavigation(siteRoot: siteRoot, config: config)).text,
                    "The menu at the top of every page.")
        }
        return AdoptionPlan(title: "Switch to \(theme.name)", changes: changes)
    }

    static func homeCollection(siteRoot: URL, config: ConfigDocument) -> String {
        if FileManager.default.fileExists(atPath: siteRoot.appending(path: "_posts").path) { return "posts" }
        let siteConfig = SiteConfig(yaml: config.values)
        return siteConfig.collections.first(where: \.output)?.name ?? siteConfig.collections.first?.name ?? "posts"
    }

    static func suggestedNavigation(siteRoot: URL, config: ConfigDocument) -> [NavigationEntry] {
        var entries = [NavigationEntry(title: "Home", url: "/")]
        let siteConfig = SiteConfig(yaml: config.values)
        for collection in siteConfig.collections where collection.output {
            if FileManager.default.fileExists(atPath: siteRoot.appending(path: "\(collection.name).md").path) {
                entries.append(NavigationEntry(title: collection.name.capitalized, url: "/\(collection.name)"))
            }
        }
        for page in ["about", "now", "contact"] where FileManager.default.fileExists(atPath: siteRoot.appending(path: "\(page).md").path) {
            entries.append(NavigationEntry(title: page.capitalized, url: "/\(page)"))
        }
        return entries
    }
}

/// The site's design tokens wherever they are: an Inkwell theme's stylesheets, or the `:root` variables of any
/// stylesheet in `assets/css` (as hand-made themes often have).
public struct DesignTokens: Sendable {
    public struct Entry: Sendable, Identifiable, Equatable {
        public var name: String
        public var label: String
        public var kind: TokenKind
        public var group: String
        public var light: String?
        public var dark: String?
        public var id: String { name }
    }

    public var entries: [Entry]
    /// Site-relative stylesheet paths holding the light and dark values.
    public var lightFile: String
    public var darkFile: String
    public var theme: ThemeManifest?

    public static func load(siteRoot: URL) -> DesignTokens? {
        let read = { (path: String) in try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8) }
        if let light = read("assets/css/inkwell.css") {
            let config = ConfigDocument(text: read("_config.yml") ?? "")
            let theme = config.value("inkwell.theme")?.string.flatMap(ThemeManifest.named)
            let lightDoc = CSSTokenDocument(text: light), darkDoc = CSSTokenDocument(text: read("assets/css/inkwell-dark.css") ?? "")
            let specs = theme?.tokens ?? []
            let names = specs.map(\.name) + lightDoc.tokens.map(\.name).filter { name in !specs.contains { $0.name == name } }
            let entries = names.map { name in
                let spec = specs.first { $0.name == name }
                let light = lightDoc.value(name, scheme: .light)
                return Entry(name: name, label: spec?.label ?? label(for: name), kind: spec?.kind ?? TokenKind.infer(name: name, value: light ?? ""),
                             group: spec?.group ?? "Other", light: light, dark: darkDoc.value(name, scheme: .light))
            }
            return DesignTokens(entries: entries, lightFile: "assets/css/inkwell.css", darkFile: "assets/css/inkwell-dark.css", theme: theme)
        }
        let folder = siteRoot.appending(path: "assets/css")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "css" || $0.pathExtension == "scss" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let doc = CSSTokenDocument(text: text)
            let tokens = doc.tokens
            guard !tokens.isEmpty else { continue }
            var order: [String] = []
            for token in tokens where !order.contains(token.name) { order.append(token.name) }
            let entries = order.map { name in
                let light = doc.value(name, scheme: .light)
                let kind = TokenKind.infer(name: name, value: light ?? doc.value(name, scheme: .dark) ?? "")
                return Entry(name: name, label: label(for: name), kind: kind, group: group(for: kind), light: light, dark: doc.value(name, scheme: .dark))
            }
            let path = "assets/css/\(file.lastPathComponent)"
            return DesignTokens(entries: entries, lightFile: path, darkFile: path, theme: nil)
        }
        return nil
    }

    /// Writes one value and returns the change made (nil when nothing changed).
    @discardableResult
    public func set(_ name: String, to value: String, scheme: ColorSchemeKind, siteRoot: URL) throws -> FileChange? {
        let path = scheme == .dark ? darkFile : lightFile
        let url = siteRoot.appending(path: path)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var doc = CSSTokenDocument(text: old)
        // Inkwell themes keep the dark palette in its own file as a plain :root block.
        let target: ColorSchemeKind = theme != nil || lightFile != darkFile ? .light : scheme
        doc.set(name, to: value, scheme: target)
        guard doc.text != old else { return nil }
        try Data(doc.text.utf8).write(to: url, options: .atomic)
        return FileChange(path: path, oldText: old, newText: doc.text, reason: "Design change")
    }

    static func label(for name: String) -> String {
        let words = name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).split(separator: "-").map(String.init)
        let text = words.filter { $0 != "color" }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func group(for kind: TokenKind) -> String {
        switch kind {
        case .color: "Colours"
        case .font: "Type"
        case .length, .number: "Layout"
        case .other: "Other"
        }
    }
}
