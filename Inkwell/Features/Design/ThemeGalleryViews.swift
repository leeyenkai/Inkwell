import AppKit
import InkwellKit
import SwiftUI
import WebKit

/// A theme as a picture of its home page (the dark one in dark mode), with its name and what it is like.
struct ThemeTile: View {
    var theme: ThemeManifest
    var selected: Bool
    var current = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemePicture(theme: theme, dark: colorScheme == .dark)
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            HStack(spacing: 6) {
                Text(theme.name).font(.headline)
                if current {
                    Text("In use").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
            Text(theme.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                 lineWidth: selected ? 2 : 0.5))
        .contentShape(Rectangle())
    }
}

/// The rendered picture of a theme, or its colours when there is no picture yet.
struct ThemePicture: View {
    var theme: ThemeManifest
    var dark: Bool

    @MainActor static var cache: [URL: NSImage] = [:]

    var image: NSImage? {
        guard let url = theme.previewImage(dark: dark) else { return nil }
        if let cached = Self.cache[url] { return cached }
        let image = NSImage(contentsOf: url)
        Self.cache[url] = image
        return image
    }

    var body: some View {
        if let image {
            Color.clear.overlay(alignment: .top) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            }
            .clipped()
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) {
                swatch(dark: false)
                swatch(dark: true)
            }
            .accessibilityHidden(true)
        }
    }

    func color(_ name: String, dark: Bool) -> Color {
        let token = theme.tokens.first { $0.name == name }
        return Color(hex: (dark ? token?.dark : token?.light) ?? "#888888")
    }

    func swatch(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color("--text", dark: dark)).frame(width: 40, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(color("--accent", dark: dark)).frame(width: 52, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(color("--muted", dark: dark)).frame(width: 60, height: 3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color("--bg", dark: dark))
    }
}

/// A copy of the person's site with a theme applied, in a temporary folder, for the gallery's live preview.
/// The site's own folder is copied once; each theme then gets its own copy, made in the background and kept while the gallery is open.
@Observable
final class ThemeTrialPreview {
    nonisolated struct Trial: Sendable {
        var root: URL
        var resources: SiteResources
        var home: String
        var post: String?
        var page: String?
        var alwaysDark: Bool
    }

    let siteRoot: URL
    let themeRoot: URL?
    private(set) var trial: Trial?
    private(set) var isWorking = false
    private(set) var failure: String?
    /// Bumped whenever a different copy is shown, so the web view reloads.
    private(set) var revision = 0
    private var trials: [String: Trial] = [:]
    private var task: Task<Void, Never>?
    private let work = FileManager.default.temporaryDirectory
        .appending(path: "inkwell-theme-trial-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(siteRoot: URL, themeRoot: URL?) {
        self.siteRoot = siteRoot
        self.themeRoot = themeRoot
    }

    func show(_ theme: ThemeManifest) {
        task?.cancel()
        failure = nil
        if let ready = trials[theme.id] {
            trial = ready
            revision += 1
            isWorking = false
            return
        }
        isWorking = true
        let siteRoot = siteRoot, themeRoot = themeRoot, work = work, sass = AppModel.sass
        task = Task {
            let made = await Task.detached(priority: .userInitiated) { () -> Result<Trial, any Error> in
                Result {
                    let base = work.appending(path: "site", directoryHint: .isDirectory)
                    if !FileManager.default.fileExists(atPath: base.path) { try ThemeTrial.copySite(from: siteRoot, to: base) }
                    let root = work.appending(path: theme.id, directoryHint: .isDirectory)
                    try ThemeTrial.make(theme: theme, site: base, at: root)
                    let site = try SiteLoader.load(root)
                    let pages = ThemeTrial.samplePages(in: site)
                    let resources = SiteResources(builder: PreviewBuilder(site: site, timeZone: site.config.timeZone, themeRoot: themeRoot),
                                                  themeRoot: themeRoot, sass: sass)
                    let config = ConfigDocument(text: (try? String(contentsOf: root.appending(path: "_config.yml"), encoding: .utf8)) ?? "")
                    return Trial(root: root, resources: resources, home: pages.home, post: pages.post, page: pages.page,
                                 alwaysDark: config.value("inkwell.appearance")?.string == "dark")
                }
            }.value
            guard !Task.isCancelled else { return }
            switch made {
            case let .success(made):
                trials[theme.id] = made
                trial = made
                revision += 1
            case let .failure(error):
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// Removes the temporary copies.
    func discard() {
        task?.cancel()
        trials = [:]
        trial = nil
        let work = work
        Task.detached { try? FileManager.default.removeItem(at: work) }
    }
}

/// The gallery's preview of a theme trial: the site's pages through the preview's scheme handler, zoomed to fit.
struct TrialWebView: NSViewRepresentable {
    var address: String
    var root: URL
    var resources: SiteResources
    var revision: Int
    var dark: Bool
    var zoom: CGFloat

    final class Coordinator {
        let handler: SiteSchemeHandler
        var loaded: (String, Int)?
        init(root: URL) { handler = SiteSchemeHandler(root: root) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: SiteSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.handler.root = root
        c.handler.baseurl = resources.baseurl
        c.handler.resources = resources
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if abs(web.pageZoom - zoom) > 0.001 { web.pageZoom = zoom }
        guard c.loaded.map({ $0 != address || $1 != revision }) ?? true,
              let url = SitePreview.url(resources.baseurl + address) else { return }
        c.loaded = (address, revision)
        web.load(URLRequest(url: url))
    }
}

struct ThemeGallery: View {
    var design: DesignModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var chosen: ThemeManifest?
    @State private var plan: AdoptionPlan?
    @State private var expanded: String?
    @State private var preview: ThemeTrialPreview?
    @State private var page = TrialPage.home
    @State private var dark = false
    @State private var phone = false
    let themes = ThemeManifest.bundled()

    enum TrialPage: Hashable { case home, post, page }

    var selected: ThemeManifest? { chosen ?? themes.first { $0.id == design.theme?.id } ?? themes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan {
                Text(plan.title).font(.title2.weight(.semibold))
                review(plan)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Choose a theme").font(.title2.weight(.semibold))
                    Spacer()
                    Text("Themes change how every page looks. Your posts and pages stay exactly as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)], spacing: 10) {
                            ForEach(themes) { theme in
                                ThemeTile(theme: theme, selected: theme.id == selected?.id, current: theme.id == design.theme?.id)
                                    .choosable(theme.name, selected: theme.id == selected?.id) { choose(theme) }
                            }
                        }
                        .padding(2)
                    }
                    .frame(width: 400)
                    livePreview
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Use This Theme…") {
                        if let selected { plan = design.plan(for: selected) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || selected?.id == design.theme?.id)
                }
            }
        }
        .padding(22)
        .frame(width: 1120, height: 720)
        .onAppear {
            dark = colorScheme == .dark
            // `--theme-gallery --gallery-theme <id>` opens on one theme, for checking it.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--gallery-theme"), i + 1 < args.count { chosen = ThemeManifest.named(args[i + 1]) }
            let trial = ThemeTrialPreview(siteRoot: design.root, themeRoot: design.themeRoot)
            preview = trial
            if let selected { trial.show(selected) }
        }
        .onDisappear { preview?.discard() }
    }

    func choose(_ theme: ThemeManifest) {
        chosen = theme
        preview?.show(theme)
    }

    var address: String? {
        guard let trial = preview?.trial else { return nil }
        switch page {
        case .home: return trial.home
        case .post: return trial.post ?? trial.home
        case .page: return trial.page ?? trial.home
        }
    }

    var livePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Page", selection: $page) {
                    Text("Home").tag(TrialPage.home)
                    Text("A post").tag(TrialPage.post)
                    Text("A page").tag(TrialPage.page)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Width", selection: $phone) {
                    Image(systemName: "desktopcomputer").help("Desktop").accessibilityLabel("Desktop").tag(false)
                    Image(systemName: "iphone").help("Phone").accessibilityLabel("Phone").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Appearance", selection: $dark) {
                    Image(systemName: "sun.max").help("Light mode").accessibilityLabel("Light mode").tag(false)
                    Image(systemName: "moon").help("Dark mode").accessibilityLabel("Dark mode").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if preview?.isWorking == true {
                    ProgressView().controlSize(.small)
                    Text("Preparing preview…").font(.caption).foregroundStyle(.secondary)
                } else if preview?.trial?.alwaysDark == true {
                    Text("This theme is always dark. You can change that in its options.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            GeometryReader { geo in
                HStack {
                    Spacer(minLength: 0)
                    if let trial = preview?.trial, let address {
                        // Desktop pages are laid out 1280 points wide and shown smaller, as on a real screen.
                        TrialWebView(address: address, root: trial.root, resources: trial.resources, revision: preview?.revision ?? 0,
                                     dark: dark, zoom: phone ? 1 : min(1, geo.size.width / 1280))
                            .frame(width: phone ? min(390, geo.size.width) : geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: phone ? 18 : 0))
                            .padding(.vertical, phone ? 10 : 0)
                            .opacity(preview?.isWorking == true ? 0.55 : 1)
                            .accessibilityLabel(String(localized: "Preview of \(selected?.name ?? "") with your posts"))
                    } else if let failure = preview?.failure {
                        Text(failure).foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView()
                    }
                    Spacer(minLength: 0)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    func review(_ plan: AdoptionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(design.isInkwellTheme
                ? "Inkwell updates these files. Nothing goes live until you publish."
                : "Your current layouts with the same names are replaced; anything else in your site is left alone. Nothing goes live until you publish.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(change.kind).font(.caption.weight(.semibold))
                                    .foregroundStyle(change.oldText == nil ? .green : .orange)
                                    .frame(width: 54, alignment: .leading)
                                Text(change.path).font(.callout.monospaced())
                                Spacer()
                                Button(expanded == change.path ? "Hide" : "Show") {
                                    expanded = expanded == change.path ? nil : change.path
                                }
                                .buttonStyle(.link)
                            }
                            Text(change.reason).font(.caption).foregroundStyle(.secondary).padding(.leading, 62)
                            if expanded == change.path {
                                Text(change.newText ?? "")
                                    .font(.caption.monospaced())
                                    .lineLimit(40)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button("Back") { self.plan = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Theme") {
                    design.apply(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
