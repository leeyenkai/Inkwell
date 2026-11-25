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

    /// Requests still being answered; one WebKit stopped must not be answered.
    private var running: Set<ObjectIdentifier> = []

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path(percentEncoded: false)
        let id = ObjectIdentifier(task)
        running.insert(id)
        let resources = resources, root = root, baseurl = baseurl
        Task {
            // Pages render Liquid and stylesheets may compile Sass: both off the main thread, so typing stays smooth.
            let response = await Task.detached {
                resources?.response(for: path) ?? Self.file(path: path, root: root, baseurl: baseurl)
            }.value
            guard running.remove(id) != nil else { return }
            let headers = ["Content-Type": response.mimeType, "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(response.data)
            task.didFinish()
        }
    }

    nonisolated static func file(path requested: String, root: URL, baseurl: String) -> SiteResources.Response {
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

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }
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
    /// Edits made on the page itself (SPEC §4.12, W3), for pages marked by `PageEditing`.
    var onPageEdit: (([String: Any]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The newest preview, for the self-tests to act in.
    @MainActor static weak var latest: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let handler = SiteSchemeHandler(root: root)
        handler.baseurl = baseurl
        handler.resources = resources
        config.setURLSchemeHandler(handler, forURLScheme: SiteSchemeHandler.scheme)
        context.coordinator.handler = handler
        // The editing script acts only on elements the page was marked with, so other previews are unaffected.
        config.userContentController.addUserScript(WKUserScript(source: PageEditingScript.source, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: PageEditingScript.handlerName)
        let web = WKWebView(frame: .zero, configuration: config)
        Self.latest = web
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel(String(localized: "Preview"))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.handler?.root = root
        c.handler?.baseurl = baseurl
        c.handler?.resources = resources
        c.onNavigate = onNavigate
        c.onPageEdit = onPageEdit
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var handler: SiteSchemeHandler?
        var onPageEdit: (([String: Any]) -> Void)?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            onPageEdit?(body)
        }

        var html: String?
        var loadedURL: String?
        var isLoaded = false
        var reloadToken = 0
        var browsing = false
        var onNavigate: ((String) -> Void)?

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            isLoaded = true
            Self.snapshotIfAsked(webView)
            if browsing, let url = webView.url, url.scheme == SiteSchemeHandler.scheme {
                let path = url.path(percentEncoded: false)
                loadedURL = path
                onNavigate?(path)
            }
        }

        /// `--snapshot-preview <file.png>` saves what the preview shows, since window captures leave web views blank.
        static func snapshotIfAsked(_ webView: WKWebView) {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--snapshot-preview"), index + 1 < args.count else { return }
            let path = args[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard let image = try? await webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(filePath: path))
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
                                    resources: model.siteResources, appearance: model.previewAppearance,
                                    onPageEdit: editsOnPage ? { model.applyPageEdit($0) } : nil)
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
        // A theme that finishes downloading brings a new builder with its layouts.
        .onChange(of: model.previewBuilder.map(ObjectIdentifier.init)) { render() }
        .onChange(of: model.editOnPage) { render() }
    }

    var editsOnPage: Bool {
        model.editOnPage && model.site?.kind != .generated && (editor.document.isStatic || model.site?.kind.servesFilesAsIs == true)
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
        // A page GitHub serves as it is shows as it is, with no layout or Liquid; marked for editing on the page.
        if editor.document.isStatic || builder.site.kind.servesFilesAsIs {
            let html = editsOnPage ? PageEditing.regions(in: editor.fullText).annotated : editor.fullText
            page = PreviewPage(html: html, unsupportedTags: [])
            return
        }
        page = builder.render(text: editor.fullText, relativePath: editor.document.relativePath, url: editor.currentURL)
    }
}

/// Lets the web view hold its message handler without keeping the coordinator alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The preview's side of editing on the page: a click makes a marked element editable, leaving it (or Return) sends
/// the new text, Escape puts the old text back, and a click on a marked picture asks for a new one.
enum PageEditingScript {
    static let handlerName = "inkwell"

    static var source: String {
        let note = String(localized: "Edit this in the source beside the preview: it has other tags inside, or a script makes it.")
        let json = (try? String(data: JSONEncoder().encode(note), encoding: .utf8)) ?? "\"\""
        return """
        (() => {
          if (window.__inkwellEditing) return;
          window.__inkwellEditing = true;
          const note = \(json);
          const post = (m) => window.webkit?.messageHandlers?.inkwell?.postMessage(m);
          const marked = () => document.querySelector('[data-ik-text],[data-ik-img]') !== null;
          const style = document.createElement('style');
          style.textContent = `
            [data-ik-text]:hover, [data-ik-img]:hover { outline: 2px dashed rgba(10,132,255,.75); outline-offset: 3px; cursor: text; }
            [data-ik-img]:hover { cursor: pointer; }
            [data-ik-text][contenteditable] { outline: 2px solid rgba(10,132,255,.95); outline-offset: 3px; }
            .inkwell-note { position: fixed; z-index: 2147483647; max-width: 300px; padding: 8px 10px; border-radius: 8px;
              font: 13px -apple-system, sans-serif; color: #fff; background: rgba(30,30,30,.92); pointer-events: none; }`;
          document.documentElement.appendChild(style);
          let shown = null;
          const showNote = (x, y) => {
            shown?.remove();
            shown = document.createElement('div');
            shown.className = 'inkwell-note';
            shown.textContent = note;
            shown.style.left = Math.min(x + 12, innerWidth - 320) + 'px';
            shown.style.top = (y + 12) + 'px';
            document.documentElement.appendChild(shown);
            const mine = shown;
            setTimeout(() => mine.remove(), 2600);
          };
          document.addEventListener('click', (e) => {
            if (!marked()) return;
            const img = e.target.closest?.('[data-ik-img]');
            const text = e.target.closest?.('[data-ik-text]');
            if (img || text || e.target.closest?.('a')) { e.preventDefault(); }
            if (img) { e.stopPropagation(); post({ kind: 'image', index: Number(img.dataset.ikImg) }); return; }
            if (text) {
              e.stopPropagation();
              if (text.isContentEditable) return;
              text.dataset.ikBefore = text.textContent;
              text.contentEditable = 'plaintext-only';
              text.focus();
              return;
            }
            const own = [...(e.target.childNodes || [])].some((n) => n.nodeType === 3 && n.textContent.trim());
            if (own && e.target !== document.body) showNote(e.clientX, e.clientY);
          }, true);
          document.addEventListener('keydown', (e) => {
            const el = e.target.closest?.('[data-ik-text]');
            if (!el || !el.isContentEditable) return;
            if (e.key === 'Enter') { e.preventDefault(); el.blur(); }
            if (e.key === 'Escape') { el.textContent = el.dataset.ikBefore ?? el.textContent; el.blur(); }
          }, true);
          document.addEventListener('focusout', (e) => {
            const el = e.target.closest?.('[data-ik-text]');
            if (!el || !el.isContentEditable) return;
            el.removeAttribute('contenteditable');
            const before = el.dataset.ikBefore ?? '';
            delete el.dataset.ikBefore;
            if (el.textContent !== before) post({ kind: 'text', index: Number(el.dataset.ikText), before, after: el.textContent });
          }, true);
        })();
        """
    }
}
