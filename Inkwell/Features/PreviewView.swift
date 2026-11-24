import InkwellKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves the site's own files (CSS, images, fonts) to the preview, so `/assets/...` resolves as it does on the live site.
final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "inkwell-site"
    var root: URL
    var baseurl = ""

    init(root: URL) {
        self.root = root
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path.removingPercentEncoding ?? url.path
        // Project sites live under /<repository>/; files are at the site root here.
        if !baseurl.isEmpty, path.hasPrefix(baseurl) { path = String(path.dropFirst(baseurl.count)) }
        if path.hasSuffix("/") { path += "index.html" }
        let file = root.appending(path: String(path.drop { $0 == "/" })).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}

struct SitePreview: NSViewRepresentable {
    var html: String
    var pageURL: String
    var root: URL
    var baseurl = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let handler = SiteSchemeHandler(root: root)
        handler.baseurl = baseurl
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
        guard c.html != html else { return }
        let base = URL(string: "\(SiteSchemeHandler.scheme)://site\(pageURL.hasPrefix("/") ? pageURL : "/" + pageURL)")
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

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            isLoaded = true
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.fragment != nil, url.scheme == SiteSchemeHandler.scheme { return .allow }
            if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
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
                        SitePreview(html: page.html, pageURL: editor.currentURL, root: root, baseurl: model.site?.config.baseurl ?? "")
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
