import InkwellKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Answers the preview's requests the way the built site would (pages, theme files, compiled Sass), so `/assets/...`
/// and links resolve as on the live site.
final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "inkwell-site"
    var root: URL
    var baseurl = ""
    var resources: SiteResources?

    init(root: URL) {
        self.root = root
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path(percentEncoded: false)
        let response: SiteResources.Response = if let resources {
            resources.response(for: path)
        } else {
            Self.file(path: path, root: root, baseurl: baseurl)
        }
        let headers = ["Content-Type": response.mimeType, "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(response.data)
        task.didFinish()
    }

    static func file(path requested: String, root: URL, baseurl: String) -> SiteResources.Response {
        var path = requested
        if !baseurl.isEmpty, path.hasPrefix(baseurl) { path = String(path.dropFirst(baseurl.count)) }
        if path.hasSuffix("/") { path += "index.html" }
        let file = root.appending(path: String(path.drop { $0 == "/" })).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            return SiteResources.Response(status: 404, data: Data(), mimeType: "text/plain")
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return SiteResources.Response(status: 200, data: data, mimeType: mime)
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}

struct SitePreview: NSViewRepresentable {
    /// Either a page's HTML (the editor's live preview) or an address to browse (the Design preview).
    var html: String = ""
    var address: String?
    var pageURL: String = "/"
    var root: URL
    var baseurl = ""
    var resources: SiteResources?
    /// Changing this reloads the whole page, for changes the HTML does not show (stylesheets, images).
    var reloadToken = 0
    var appearance: AppModel.PreviewAppearance = .system
    var onNavigate: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let handler = SiteSchemeHandler(root: root)
        handler.baseurl = baseurl
        handler.resources = resources
        config.setURLSchemeHandler(handler, forURLScheme: SiteSchemeHandler.scheme)
        context.coordinator.handler = handler
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Preview")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.handler?.root = root
        c.handler?.baseurl = baseurl
        c.handler?.resources = resources
        c.onNavigate = onNavigate
        c.browsing = address != nil
        switch appearance {
        case .system: web.appearance = nil
        case .light: web.appearance = NSAppearance(named: .aqua)
        case .dark: web.appearance = NSAppearance(named: .darkAqua)
        }
        let reload = c.reloadToken != reloadToken
        c.reloadToken = reloadToken

        if let address {
            guard reload || c.loadedURL != address else { return }
            c.loadedURL = address
            if let url = Self.url(address) { web.load(URLRequest(url: url)) }
            return
        }
        if reload { c.html = nil }
        guard c.html != html else { return }
        let base = Self.url(pageURL)
        // Same page: swap the body in place so the scroll position stays where the writer is reading.
        if c.loadedURL == pageURL, c.isLoaded, let body = Self.body(of: html), let old = c.html.flatMap(Self.head), old == Self.head(html) {
            let json = (try? String(data: JSONEncoder().encode(body), encoding: .utf8)) ?? "\"\""
            web.evaluateJavaScript("document.body.innerHTML = \(json);")
        } else {
            c.isLoaded = false
            web.loadHTMLString(html, baseURL: base)
        }
        c.html = html
        c.loadedURL = pageURL
    }

    static func url(_ path: String) -> URL? {
        URL(string: "\(SiteSchemeHandler.scheme)://site\(path.hasPrefix("/") ? path : "/" + path)")
    }

    static func body(of html: String) -> String? {
        guard let open = html.range(of: "<body[^>]*>", options: .regularExpression),
              let close = html.range(of: "</body>", options: .backwards) else { return nil }
        return String(html[open.upperBound ..< close.lowerBound])
    }

    static func head(_ html: String) -> String? {
        guard let close = html.range(of: "<body") else { return nil }
        return String(html[..<close.lowerBound])
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var handler: SiteSchemeHandler?
        var html: String?
        var loadedURL: String?
        var isLoaded = false
        var reloadToken = 0
        var browsing = false
        var onNavigate: ((String) -> Void)?

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            isLoaded = true
            if browsing, let url = webView.url, url.scheme == SiteSchemeHandler.scheme {
                let path = url.path(percentEncoded: false)
                loadedURL = path
                onNavigate?(path)
            }
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.scheme == SiteSchemeHandler.scheme { return browsing || url.fragment != nil ? .allow : .cancel }
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}

struct PreviewPane: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument
    @State private var page: PreviewPage?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Width", selection: $model.previewWidth) {
                    Label("Desktop", systemImage: "desktopcomputer").tag(AppModel.PreviewWidth.desktop)
                    Label("Phone", systemImage: "iphone").tag(AppModel.PreviewWidth.phone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let unsupported = page?.unsupportedTags, !unsupported.isEmpty {
                    Label("Approximate", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("These template tags are not run in the preview: \(unsupported.joined(separator: ", "))")
                }
                Text(editor.displayURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            GeometryReader { geo in
                HStack {
                    Spacer(minLength: 0)
                    if let page, let root = model.site?.root {
                        SitePreview(html: page.html, pageURL: editor.currentURL, root: root, baseurl: model.site?.config.baseurl ?? "",
                                    resources: model.siteResources, appearance: model.previewAppearance)
                            .frame(width: model.previewWidth == .phone ? min(390, geo.size.width) : geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: model.previewWidth == .phone ? 18 : 0))
                            .overlay {
                                if model.previewWidth == .phone {
                                    RoundedRectangle(cornerRadius: 18).strokeBorder(.separator, lineWidth: 1)
                                }
                            }
                            .padding(.vertical, model.previewWidth == .phone ? 12 : 0)
                    }
                    Spacer(minLength: 0)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear(perform: render)
        .onChange(of: editor.fullText) { scheduleRender() }
        .onChange(of: editor.document.id) { render() }
    }

    func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            render()
        }
    }

    func render() {
        guard let builder = model.previewBuilder else { return }
        page = builder.render(text: editor.fullText, relativePath: editor.document.relativePath, url: editor.currentURL)
    }
}
