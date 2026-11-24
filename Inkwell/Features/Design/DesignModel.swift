import AppKit
import InkwellKit
import Observation

/// The site's design as editable values: theme tokens, `_config.yml` settings and the navigation menu.
/// Every change is written to the site's files straight away, so it shows in the preview and under
/// "Unpublished changes", and goes live with the next publish.
@Observable
final class DesignModel {
    let root: URL
    private(set) var tokens: DesignTokens?
    private(set) var config: ConfigDocument
    private(set) var navigation: NavigationDocument
    private(set) var hasNavigationFile: Bool
    /// Bumped on every change, so the preview reloads.
    private(set) var revision = 0
    var previewPage = "/"
    private weak var model: AppModel?

    init(root: URL, model: AppModel) {
        self.root = root
        self.model = model
        config = ConfigDocument(text: "")
        navigation = NavigationDocument(entries: [])
        hasNavigationFile = false
        reload()
    }

    func reload() {
        tokens = DesignTokens.load(siteRoot: root, themeRoot: model?.themeRoot)
        config = ConfigDocument(text: read("_config.yml") ?? "")
        let navText = read("_data/navigation.yml")
        hasNavigationFile = navText != nil
        navigation = NavigationDocument(text: navText ?? "")
        revision += 1
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func write(_ path: String, _ text: String) {
        let url = root.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            model?.errorMessage = "Could not save \(path): \(error.localizedDescription)"
        }
    }

    /// Something under the design changed on disk (a code edit): refresh the preview and the change list.
    func bump() { changed(siteStructure: true) }

    private func changed(siteStructure: Bool = false) {
        revision += 1
        model?.refreshChanges()
        if siteStructure { model?.reloadSite() }
    }

    // MARK: Theme

    var theme: ThemeManifest? { tokens?.theme }
    var isInkwellTheme: Bool { theme != nil }

    func plan(for theme: ThemeManifest) -> AdoptionPlan {
        ThemeApplier.plan(theme: theme, siteRoot: root)
    }

    func apply(_ plan: AdoptionPlan) {
        do {
            try plan.apply(to: root)
        } catch {
            model?.errorMessage = "The theme could not be applied: \(error.localizedDescription)"
        }
        reload()
        changed(siteStructure: true)
    }

    // MARK: Tokens

    func token(_ name: String) -> DesignTokens.Entry? { tokens?.entries.first { $0.name == name } }

    func setToken(_ name: String, _ value: String, scheme: ColorSchemeKind) {
        guard let tokens else { return }
        do {
            guard try tokens.set(name, to: value, scheme: scheme, siteRoot: root) != nil else { return }
        } catch {
            model?.errorMessage = error.localizedDescription
        }
        self.tokens = DesignTokens.load(siteRoot: root, themeRoot: model?.themeRoot)
        changed()
    }

    private var pendingTokens: [String: (String, ColorSchemeKind)] = [:]
    private var tokenTask: Task<Void, Never>?

    /// For colour wells and sliders, which change continuously: saves once the value settles.
    func scheduleToken(_ name: String, _ value: String, scheme: ColorSchemeKind) {
        pendingTokens["\(name)|\(scheme.rawValue)"] = (value, scheme)
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let pending = self.pendingTokens
            self.pendingTokens = [:]
            for (key, entry) in pending {
                self.setToken(String(key.split(separator: "|")[0]), entry.0, scheme: entry.1)
            }
        }
    }

    var hasDarkPalette: Bool { tokens?.entries.contains { $0.kind == .color && $0.dark != nil } ?? false }
    var hasLightModePalette: Bool { tokens?.entries.contains { $0.kind == .color && $0.lightMode != nil } ?? false }

    /// The second palette the site has (or would get): dark mode for light sites, light mode for dark ones.
    var secondScheme: ColorSchemeKind? {
        if hasDarkPalette { return .dark }
        if hasLightModePalette { return .lightMode }
        return nil
    }

    /// Whether the default colours are dark, judged by the background.
    var defaultIsDark: Bool {
        let colors = tokens?.entries.filter { $0.kind == .color } ?? []
        let background = colors.first { $0.name.contains("bg") || $0.name.contains("background") } ?? colors.first
        return background?.light.flatMap(DesignTokens.luminance).map { $0 < 0.35 } ?? false
    }

    /// Adds the other palette, starting from the current colours with their lightness turned over.
    func addSecondPalette() {
        guard let tokens else { return }
        let scheme: ColorSchemeKind = defaultIsDark ? .lightMode : .dark
        for entry in tokens.entries where entry.kind == .color {
            guard let value = entry.light else { continue }
            _ = try? tokens.set(entry.name, to: DesignTokens.invertedLightness(value) ?? value, scheme: scheme, siteRoot: root)
        }
        self.tokens = DesignTokens.load(siteRoot: root, themeRoot: model?.themeRoot)
        changed()
    }

    /// Token groups in the order the panel shows them.
    var groups: [(String, [DesignTokens.Entry])] {
        let entries = tokens?.entries ?? []
        var order: [String] = []
        for entry in entries where !order.contains(entry.group) { order.append(entry.group) }
        return order.map { group in (group, entries.filter { $0.group == group }) }
    }

    // MARK: Settings and options

    func string(_ path: String) -> String { config.value(path)?.string ?? "" }

    func setString(_ path: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        setRaw(path, trimmed.isEmpty ? nil : YAMLFormat.quoted(trimmed))
    }

    func option(_ key: String) -> OptionValue? {
        switch config.value("inkwell.\(key)") {
        case let .bool(b)?: .flag(b)
        case let value?: value.string.map(OptionValue.text)
        case nil: theme?.defaults[key]
        }
    }

    func setOption(_ key: String, _ value: OptionValue) {
        setRaw("inkwell.\(key)", value.yaml)
    }

    func setRaw(_ path: String, _ raw: String?) {
        var updated = config
        updated.set(path, raw: raw)
        guard updated != config else { return }
        config = updated
        write("_config.yml", config.text)
        changed(siteStructure: true)
    }

    // MARK: Navigation

    func saveNavigation(_ entries: [NavigationEntry]) {
        var nav = navigation
        nav.entries = entries
        guard nav != navigation || !hasNavigationFile else { return }
        navigation = nav
        hasNavigationFile = true
        write("_data/navigation.yml", nav.text)
        changed(siteStructure: true)
    }

    // MARK: Images

    /// Copies an image into the site for use as the share image or favicon, cleaned like post images.
    func importImage(_ url: URL, slug: String) -> String? {
        do {
            return try ImageImport().importImage(at: url, siteRoot: root, slug: slug).sitePath
        } catch {
            model?.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Draws a favicon from a letter or emoji on the accent colour and saves it as `assets/favicon.png`.
    func makeFavicon(text: String, background: NSColor) -> String? {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size, flipped: false) { rect in
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 112, yRadius: 112).fill()
            let isEmoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isEmoji ? 300 : 320, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attrs)
            let bounds = string.boundingRect(with: size, options: [.usesLineFragmentOrigin])
            string.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = root.appending(path: "assets/favicon.png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            model?.errorMessage = error.localizedDescription
            return nil
        }
        changed()
        return "/assets/favicon.png"
    }

    // MARK: Preview

    /// A fresh view of the site's files for the preview to browse.
    func makeResources() -> SiteResources? {
        guard let site = try? SiteLoader.load(root) else { return nil }
        let theme = model?.themeRoot
        return SiteResources(builder: PreviewBuilder(site: site, timeZone: site.config.timeZone, themeRoot: theme), themeRoot: theme,
                             sass: AppModel.sass)
    }

    /// The page to preview, rendered with the current files.
    func previewHTML() -> (html: String, url: String)? {
        guard let site = try? SiteLoader.load(root) else { return nil }
        let builder = PreviewBuilder(site: site, timeZone: site.config.timeZone, themeRoot: model?.themeRoot)
        let doc = site.documents.first { $0.url == previewPage || $0.url == previewPage + "/" }
            ?? site.documents.first { $0.url == "/" + site.config.baseurl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            ?? site.documents.first { $0.relativePath == "index.md" || $0.relativePath == "index.html" }
            ?? site.documents.first
        guard let doc, let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { return nil }
        return (builder.render(text: text, relativePath: doc.relativePath, url: doc.url).html, doc.url)
    }

    /// Pages worth previewing while designing: the home page, section index pages and the newest post.
    var previewChoices: [(String, String)] {
        guard let site = model?.site else { return [] }
        var choices: [(String, String)] = []
        for doc in site.documents where doc.isPage { choices.append((doc.title, doc.url)) }
        if let post = site.documents.filter({ !$0.isPage }).max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            choices.append(("Newest post: \(post.title)", post.url))
        }
        return choices
    }
}
