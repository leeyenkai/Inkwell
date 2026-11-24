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
            return try? JSONDecoder().decode(ThemeManifest.self, from: data).translated()
        }
        return themes.sorted { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
    }

    public static func named(_ id: String) -> ThemeManifest? { bundled().first { $0.id == id } }

    /// Labels and the summary in the person's language, from the Themes table (theme.json stays in English).
    func translated() -> ThemeManifest {
        func text(_ english: String) -> String { Bundle.module.localizedString(forKey: english, value: english, table: "Themes") }
        var copy = self
        copy.summary = text(summary)
        copy.tokens = tokens.map { var t = $0; t.label = text(t.label); t.group = text(t.group); return t }
        copy.options = options.map { var o = $0; o.label = text(o.label); return o }
        return copy
    }

    func tokenBlock(_ scheme: ColorSchemeKind) -> String {
        var out = ":root {\n"
        for token in tokens {
            guard let value = scheme == .light ? token.light : token.dark else { continue }
            out += "    \(token.name): \(value);\n"
        }
        return out + "}\n"
    }

    var folder: URL { Self.themesFolder.appending(path: id, directoryHint: .isDirectory) }

    var stylesheet: String {
        let base = (try? String(contentsOf: Self.baseFolder.appending(path: "assets/css/inkwell-base.css"), encoding: .utf8)) ?? ""
        let own = (try? String(contentsOf: folder.appending(path: "theme.css"), encoding: .utf8)).map { "\n/* \(name) */\n" + $0 } ?? ""
        return "/* \(name) theme tokens. */\n" + tokenBlock(.light) + "\n" + base + own
    }

    /// The theme's site files: the shared base, with any file the theme has of its own in its place.
    /// The theme's manifest, stylesheet (merged into inkwell.css) and preview stay out.
    public var siteFiles: [String: String] {
        var files = BundledFiles.read(Self.baseFolder, skipping: ["assets/css/inkwell-base.css"])
        files.merge(BundledFiles.read(folder, skipping: ["theme.json", "theme.css", "preview.png", "preview-dark.png"])) { $1 }
        return files
    }

    /// A picture of the theme's home page, rendered from its real files (`--render-theme-previews`).
    public var previewImage: URL? {
        let url = folder.appending(path: "preview.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var darkStylesheet: String {
        "/* \(name) theme, dark palette. Loaded when the reader's system is in dark mode. */\n" + tokenBlock(.dark)
    }
}

/// Text files in a bundled folder, by path relative to it.
enum BundledFiles {
    static func read(_ folder: URL, skipping: Set<String> = []) -> [String: String] {
        let base = folder.standardizedFileURL.path
        var files: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            guard !skipping.contains(path), !url.lastPathComponent.hasPrefix("."), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files[path] = text
        }
        return files
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
        case (nil, _): localized("Add")
        case (_, nil): localized("Remove")
        default: localized("Change")
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
        let reasons = [
            "_layouts/default.html": localized("The page frame: header, navigation and footer."),
            "_layouts/post.html": localized("How a post looks: title, byline, date and text."),
            "_layouts/page.html": localized("How a standalone page looks."),
            "_layouts/home.html": localized("A home page that lists your latest posts."),
            "_includes/inkwell-header.html": localized("The site title and navigation."),
            "_includes/inkwell-footer.html": localized("The footer line."),
            "_includes/inkwell-post-list.html": localized("The list of posts used on the home page."),
        ]
        for (path, text) in theme.siteFiles.sorted(by: { $0.key < $1.key }) {
            propose(path, text, reasons[path] ?? localized("Part of the \(theme.name) theme."))
        }
        for change in ElementKit.changes(siteRoot: siteRoot) where !changes.contains(where: { $0.path == change.path }) {
            changes.append(change)
        }
        propose("assets/css/inkwell.css", theme.stylesheet, "The \(theme.name) colours, fonts and styles.")
        propose("assets/css/inkwell-dark.css", theme.darkStylesheet, localized("The dark palette, used when the reader’s Mac or phone is in dark mode."))

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
        propose("_config.yml", config.text, localized("Remembers the theme and its options under “inkwell:”."))

        if !FileManager.default.fileExists(atPath: siteRoot.appending(path: "_data/navigation.yml").path) {
            propose("_data/navigation.yml", NavigationDocument(entries: suggestedNavigation(siteRoot: siteRoot, config: config)).text,
                    localized("The menu at the top of every page."))
        }
        return AdoptionPlan(title: localized("Switch to \(theme.name)"), changes: changes)
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
        /// The value in a `prefers-color-scheme: light` block, for themes whose default is dark.
        public var lightMode: String?
        public var id: String { name }
    }

    public var entries: [Entry]
    /// Site-relative stylesheet paths holding the light and dark values.
    public var lightFile: String
    public var darkFile: String
    public var theme: ThemeManifest?
    /// For SCSS themes: the theme's own main stylesheet, copied into the site the first time a variable is changed.
    public var sassTemplate: URL?

    /// Whether separate light and dark palettes can be kept (not for Sass variables, which have one value each).
    public var supportsColorSchemes: Bool { sassTemplate == nil }

    public static func load(siteRoot: URL, themeRoot: URL? = nil) -> DesignTokens? {
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
                             group: spec?.group ?? localized("Other"), light: light, dark: darkDoc.value(name, scheme: .light))
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
                return Entry(name: name, label: label(for: name), kind: kind, group: group(for: kind), light: light, dark: doc.value(name, scheme: .dark),
                             lightMode: doc.value(name, scheme: .lightMode))
            }
            let path = "assets/css/\(file.lastPathComponent)"
            return DesignTokens(entries: entries, lightFile: path, darkFile: path, theme: nil)
        }
        return themeRoot.flatMap { sassTokens(siteRoot: siteRoot, themeRoot: $0) }
    }

    /// A Sass theme's `!default` variables, with the site's overrides from `assets/main.scss`.
    static func sassTokens(siteRoot: URL, themeRoot: URL) -> DesignTokens? {
        let fm = FileManager.default
        let sassFolder = themeRoot.appending(path: "_sass")
        let files = ((try? fm.contentsOfDirectory(at: sassFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "scss" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var defaults: [(String, String)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (name, value) in SassVariables.declarations(in: text, defaultsOnly: true) where !defaults.contains(where: { $0.0 == name }) {
                defaults.append((name, value))
            }
        }
        guard !defaults.isEmpty else { return nil }
        let path = "assets/main.scss"
        let overrides = (try? String(contentsOf: siteRoot.appending(path: path), encoding: .utf8))
            .map { Dictionary(SassVariables.declarations(in: $0, defaultsOnly: false), uniquingKeysWith: { $1 }) } ?? [:]
        let entries = defaults.map { name, value in
            let current = overrides[name] ?? value
            let kind = TokenKind.infer(name: name, value: current)
            return Entry(name: "$" + name, label: label(for: name), kind: kind, group: group(for: kind), light: current, dark: nil)
        }
        return DesignTokens(entries: entries, lightFile: path, darkFile: path, theme: nil,
                            sassTemplate: themeRoot.appending(path: "assets/main.scss"))
    }

    /// Writes one value and returns the change made (nil when nothing changed).
    @discardableResult
    public func set(_ name: String, to value: String, scheme: ColorSchemeKind, siteRoot: URL) throws -> FileChange? {
        if let template = sassTemplate {
            let url = siteRoot.appending(path: lightFile)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let base = existing ?? (try? String(contentsOf: template, encoding: .utf8)) ?? "---\n---\n\n"
            let updated = SassVariables.set(String(name.drop { $0 == "$" }), to: value, in: base)
            guard updated != existing else { return nil }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: url, options: .atomic)
            return FileChange(path: lightFile, oldText: existing, newText: updated, reason: localized("Design change"))
        }
        let path = scheme == .dark ? darkFile : lightFile
        let url = siteRoot.appending(path: path)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var doc = CSSTokenDocument(text: old)
        // Inkwell themes keep the dark palette in its own file as a plain :root block.
        let target: ColorSchemeKind = (theme != nil || lightFile != darkFile) && scheme == .dark ? .light : scheme
        doc.set(name, to: value, scheme: target)
        guard doc.text != old else { return nil }
        try Data(doc.text.utf8).write(to: url, options: .atomic)
        return FileChange(path: path, oldText: old, newText: doc.text, reason: localized("Design change"))
    }

    /// A starting point for the other palette: the same hues with lightness turned over (dark grey ↔ light grey).
    public static func invertedLightness(_ hex: String) -> String? {
        var digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if digits.count == 3 { digits = String(digits.flatMap { [$0, $0] }) }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        let newL = 1 - l
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = newL < 0.5 ? newL * (1 + s) : newL + s - newL * s, p = 2 * newL - q
        let (nr, ng, nb) = s == 0 ? (newL, newL, newL) : (hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3))
        return String(format: "#%02X%02X%02X", Int((nr * 255).rounded()), Int((ng * 255).rounded()), Int((nb * 255).rounded()))
    }

    /// Relative luminance of a hex colour, 0 (black) to 1 (white).
    public static func luminance(_ hex: String) -> Double? {
        var digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if digits.count == 3 { digits = String(digits.flatMap { [$0, $0] }) }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        func channel(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((value >> 16) & 0xFF) + 0.7152 * channel((value >> 8) & 0xFF) + 0.0722 * channel(value & 0xFF)
    }

    static func label(for name: String) -> String {
        let expansions = ["bg": "background", "fg": "foreground", "txt": "text", "col": "colour", "clr": "colour"]
        let words = name.trimmingCharacters(in: CharacterSet(charactersIn: "-$")).split(separator: "-").map { expansions[String($0)] ?? String($0) }
        let text = words.filter { $0 != "color" }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func group(for kind: TokenKind) -> String {
        switch kind {
        case .color: localized("Colours")
        case .font: localized("Fonts")
        case .length, .number: localized("Layout")
        case .other: localized("Other")
        }
    }
}
