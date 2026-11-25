import Foundation
import InkwellCore
import UniformTypeIdentifiers

/// The theme a site builds with, when its layouts come from somewhere else: a gem theme GitHub Pages supports
/// (`theme: minima`) or a `remote_theme: owner/repo@ref`.
public struct ThemeReference: Sendable, Hashable {
    public var owner: String
    public var repository: String
    public var ref: String?

    public init(owner: String, repository: String, ref: String?) {
        self.owner = owner
        self.repository = repository
        self.ref = ref
    }

    /// Gem themes GitHub Pages builds with, at the versions it uses.
    static let pagesThemes: [String: ThemeReference] = {
        var map = ["minima": ThemeReference(owner: "jekyll", repository: "minima", ref: "v2.5.1"),
                   "jekyll-theme-primer": ThemeReference(owner: "pages-themes", repository: "primer", ref: "v0.6.0")]
        for name in ["architect", "cayman", "dinky", "hacker", "leap-day", "merlot", "midnight", "minimal", "modernist", "slate",
                     "tactile", "time-machine"] {
            map["jekyll-theme-\(name)"] = ThemeReference(owner: "pages-themes", repository: name, ref: "v0.2.0")
        }
        return map
    }()

    public static func of(_ config: SiteConfig) -> ThemeReference? {
        if let remote = config.raw["remote_theme"]?.string {
            let parts = remote.split(separator: "@", maxSplits: 1).map(String.init)
            guard let name = parts.first else { return nil }
            let path = name.split(separator: "/").map(String.init)
            guard path.count == 2 else { return nil }
            return ThemeReference(owner: path[0], repository: path[1], ref: parts.count > 1 ? parts[1] : nil)
        }
        if let gem = config.raw["theme"]?.string { return pagesThemes[gem] }
        return nil
    }

    public var folderName: String { "\(owner)-\(repository)@\(ref ?? "default")" }
}

/// Runs the bundled `sass` (dart-sass) to turn SCSS into CSS, as GitHub Pages does when it builds.
public struct SassCompiler: Sendable {
    public var executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public enum Failure: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case let .failed(message) = self { return "Sass: \(message)" }
            return nil
        }
    }

    public func compile(_ source: String, syntax: String = "scss", loadPaths: [URL]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stdin", "--no-source-map", "--style=expanded", "--quiet"] + (syntax == "sass" ? ["--indented"] : [])
            + loadPaths.map { "--load-path=\($0.path)" }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try input.fileHandleForWriting.close()
        let css = output.fileHandleForReading.readDataToEndOfFile()
        let problems = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.failed(String(decoding: problems, as: UTF8.self)) }
        return String(decoding: css, as: UTF8.self)
    }
}

/// Answers the preview's requests the way the built site would: pages rendered through their layouts, files from the
/// site and then its theme, Liquid in files that have front matter, and `.scss` compiled when `.css` is asked for.
public final class SiteResources: @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var data: Data
        public var mimeType: String

        public init(status: Int, data: Data, mimeType: String) {
            self.status = status
            self.data = data
            self.mimeType = mimeType
        }
    }

    public let siteRoot: URL
    public let themeRoot: URL?
    public let baseurl: String
    let builder: PreviewBuilder
    let sass: SassCompiler?
    private var cssCache: [String: (Date, Data)] = [:]
    private let lock = NSLock()

    public init(builder: PreviewBuilder, themeRoot: URL?, sass: SassCompiler?) {
        self.builder = builder
        siteRoot = builder.site.root
        self.themeRoot = themeRoot
        baseurl = builder.site.config.baseurl
        self.sass = sass
    }

    public func response(for requestPath: String) -> Response {
        var path = requestPath.removingPercentEncoding ?? requestPath
        if !baseurl.isEmpty, path.hasPrefix(baseurl) { path = String(path.dropFirst(baseurl.count)) }
        if path.isEmpty { path = "/" }

        if let page = builder.page(at: path) {
            return Response(status: 200, data: Data(page.html.utf8), mimeType: "text/html")
        }
        let relative = String(path.drop { $0 == "/" })
        let asIs = builder.site.kind.servesFilesAsIs
        if asIs || !relative.hasPrefix("_"), !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            if let file = locate(relative) ?? locateIndex(relative) { return serve(file, relative: relative) }
            if !asIs, relative.hasSuffix(".css"), let css = compiledCSS(for: String(relative.dropLast(4))) {
                return Response(status: 200, data: css, mimeType: "text/css")
            }
        }
        if let notFound = builder.page(at: "/404.html") {
            return Response(status: 404, data: Data(notFound.html.utf8), mimeType: "text/html")
        }
        if let file = locate("404.html") {
            return Response(status: 404, data: serve(file, relative: "404.html").data, mimeType: "text/html")
        }
        return Response(status: 404, data: Data("Not found: \(path)".utf8), mimeType: "text/plain")
    }

    func locate(_ relative: String) -> URL? {
        guard !relative.isEmpty else { return nil }
        for root in [siteRoot, themeRoot].compactMap({ $0 }) {
            let url = root.appending(path: relative).standardizedFileURL
            var isDirectory: ObjCBool = false
            if url.path.hasPrefix(root.standardizedFileURL.path), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    /// A folder address as GitHub Pages answers it: `index.html` inside it, or `name.html` beside it.
    func locateIndex(_ relative: String) -> URL? {
        let folder = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
        if folder.isEmpty { return locate("index.html") }
        return locate(folder + "/index.html") ?? (relative.hasSuffix("/") ? nil : locate(folder + ".html"))
    }

    func serve(_ file: URL, relative: String) -> Response {
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard let data = try? Data(contentsOf: file) else { return Response(status: 404, data: Data(), mimeType: "text/plain") }
        // Text files with front matter (feeds, CSS with Liquid) are run through Liquid, as Jekyll does.
        if !builder.site.kind.servesFilesAsIs, data.starts(with: Data("---".utf8)), let text = String(data: data, encoding: .utf8),
           FrontMatterDocument(text: text).hasFrontMatter, ["xml", "css", "txt", "json", "js", "html", "htm"].contains(file.pathExtension.lowercased()) {
            let rendered = builder.render(text: text, relativePath: relative, url: "/" + relative)
            return Response(status: 200, data: Data(rendered.html.utf8), mimeType: mime)
        }
        return Response(status: 200, data: data, mimeType: mime)
    }

    /// `assets/main.css` from `assets/main.scss` (or `.sass`), with `_sass` folders of the site and theme on the load path.
    func compiledCSS(for base: String) -> Data? {
        guard let sass else { return nil }
        for ext in ["scss", "sass"] {
            guard let file = locate("\(base).\(ext)"), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            lock.lock()
            let cached = cssCache[file.path]
            lock.unlock()
            if let cached, cached.0 == modified { return cached.1 }
            let liquid = builder.render(text: text, relativePath: "\(base).\(ext)", url: "/\(base).css").html
            let loadPaths = [siteRoot, themeRoot].compactMap { $0 }.map { $0.appending(path: "_sass") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let css: String
            do {
                css = try sass.compile(liquid, syntax: ext, loadPaths: loadPaths)
            } catch {
                css = "/* \(error.localizedDescription.replacingOccurrences(of: "*/", with: "* /")) */"
            }
            let data = Data(css.utf8)
            lock.lock()
            cssCache[file.path] = (modified, data)
            lock.unlock()
            return data
        }
        return nil
    }
}
