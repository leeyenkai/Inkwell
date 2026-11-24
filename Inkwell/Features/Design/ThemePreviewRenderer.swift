import AppKit
import InkwellKit
import WebKit

/// Draws a site's pages offscreen through the same scheme handler as the preview, so the pictures are the theme's real files.
final class PageSnapshotter: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private let handler = SiteSchemeHandler(root: URL(fileURLWithPath: NSTemporaryDirectory()))
    private let window: NSWindow
    private var loaded: CheckedContinuation<Void, Never>?

    init(size: CGSize) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: SiteSchemeHandler.scheme)
        web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        // Far off screen: a web view in a window lays out and paints like the real preview.
        // A window taller than the screen never paints, so a tall page sits in a window of desktop height.
        let frame = CGRect(x: -30000, y: -30000, width: size.width, height: min(size.height, 800))
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        web.frame = CGRect(x: 0, y: frame.height - size.height, width: size.width, height: size.height)
        container.addSubview(web)
        window.contentView = container
        window.orderFrontRegardless()
        web.navigationDelegate = self
    }

    func close() { window.close() }

    /// A picture of one page of the site at `root`, about `width` pixels wide.
    func snapshot(root: URL, path: String, dark: Bool, width: CGFloat) async -> NSImage? {
        guard let site = try? SiteLoader.load(root), let url = SitePreview.url(site.config.baseurl + path) else { return nil }
        handler.root = root
        handler.baseurl = site.config.baseurl
        let builder = PreviewBuilder(site: site, timeZone: site.config.timeZone)
        handler.resources = SiteResources(builder: builder, themeRoot: nil, sass: AppModel.sass)
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await withCheckedContinuation { continuation in
            loaded = continuation
            web.load(URLRequest(url: url))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish()
            }
        }
        // Images decode and fonts settle after the load event.
        try? await Task.sleep(for: .milliseconds(500))
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        // The snapshot width is in points; the picture has the screen's pixels per point.
        config.snapshotWidth = NSNumber(value: Double(width / max(1, window.backingScaleFactor)))
        return try? await web.takeSnapshot(configuration: config)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) { finish() }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) { finish() }
    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: any Error) { finish() }

    private func finish() {
        loaded?.resume()
        loaded = nil
    }
}

enum ThemePreviewRenderer {
    /// `--render-theme-previews <folder>`: each bundled theme applied to the sample site, its home page drawn at desktop size,
    /// light and dark, into `<folder>/<theme id>/preview.png` and `preview-dark.png`.
    /// `--preview-path <address>` and `--preview-size <width>x<height>` draw another page or size instead (for checking a theme).
    static func renderAll(into folder: URL, arguments: [String]) async -> Bool {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let path = value("--preview-path") ?? "/"
        let numbers = value("--preview-size").map { $0.split(separator: "x").compactMap { Double($0) } }
        let size = numbers.flatMap { $0.count == 2 ? $0 : nil } ?? [1280, 800]
        let snapshotter = PageSnapshotter(size: CGSize(width: size[0], height: size[1]))
        defer { snapshotter.close() }
        let work = FileManager.default.temporaryDirectory
            .appending(path: "inkwell-theme-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        var ok = true
        for theme in ThemeManifest.bundled() {
            let trial = work.appending(path: theme.id, directoryHint: .isDirectory)
            do {
                try ThemeTrial.make(theme: theme, site: ThemeManifest.sampleSite, at: trial)
            } catch {
                print("\(theme.id): \(error.localizedDescription)")
                ok = false
                continue
            }
            for dark in [false, true] {
                let width = size[0] > 1000 ? 1200 : size[0] * 2
                guard let image = await snapshotter.snapshot(root: trial, path: path, dark: dark, width: width),
                      let data = PNGWriter.data(for: image, budget: 240_000) else {
                    print("\(theme.id): could not draw the \(dark ? "dark" : "light") preview")
                    ok = false
                    continue
                }
                let out = folder.appending(path: theme.id).appending(path: dark ? "preview-dark.png" : "preview.png")
                do {
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: out, options: .atomic)
                    print("\(theme.id) \(dark ? "dark" : "light"): \(data.count / 1024) KB")
                } catch {
                    print("\(theme.id): \(error.localizedDescription)")
                    ok = false
                }
            }
        }
        return ok
    }
}

/// PNG data for a picture, reduced to 256 colours when the full-colour file is over the size budget.
enum PNGWriter {
    static func data(for image: NSImage, budget: Int) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let full = encode(cgImage) else { return nil }
        if full.count <= budget { return full }
        return quantized(cgImage).flatMap(encode).map { $0.count < full.count ? $0 : full } ?? full
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Median cut over a 15-bit histogram, then each pixel mapped to its box's colour: an indexed image of at most 256 colours.
    static func quantized(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func bin(_ i: Int) -> Int { Int(pixels[i] >> 3) << 10 | Int(pixels[i + 1] >> 3) << 5 | Int(pixels[i + 2] >> 3) }
        var counts = [Int](repeating: 0, count: 32768), sums = [Int](repeating: 0, count: 32768 * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = bin(i)
            counts[b] += 1
            for c in 0 ..< 3 { sums[b * 3 + c] += Int(pixels[i + c]) }
        }
        var boxes: [[Int]] = [counts.indices.filter { counts[$0] > 0 }]
        func channel(_ b: Int, _ c: Int) -> Int { (b >> (10 - 5 * c)) & 31 }
        while boxes.count < 256 {
            var best = -1, bestScore = 0, bestChannel = 0
            for (index, box) in boxes.enumerated() where box.count > 1 {
                for c in 0 ..< 3 {
                    let values = box.map { channel($0, c) }
                    let range = values.max()! - values.min()!
                    let score = range * box.reduce(0) { $0 + counts[$1] }
                    if score > bestScore { (best, bestScore, bestChannel) = (index, score, c) }
                }
            }
            guard best >= 0 else { break }
            let sorted = boxes[best].sorted { channel($0, bestChannel) < channel($1, bestChannel) }
            let total = sorted.reduce(0) { $0 + counts[$1] }
            var running = 0, cut = 1
            for (i, b) in sorted.enumerated() {
                running += counts[b]
                if running * 2 >= total { cut = max(1, min(sorted.count - 1, i + 1)); break }
            }
            boxes[best] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        var table = [UInt8](), lookup = [UInt8](repeating: 0, count: 32768)
        for (index, box) in boxes.enumerated() {
            let weight = max(1, box.reduce(0) { $0 + counts[$1] })
            // The true average of the pixels in the box, so flat colours (backgrounds) come out exact.
            for c in 0 ..< 3 {
                let sum = box.reduce(0) { $0 + sums[$1 * 3 + c] }
                table.append(UInt8(min(255, sum / weight)))
            }
            for b in box { lookup[b] = UInt8(index) }
        }
        var indexed = [UInt8](repeating: 0, count: width * height)
        for p in 0 ..< width * height { indexed[p] = lookup[bin(p * 4)] }
        guard let palette = CGColorSpace(indexedBaseSpace: space, last: boxes.count - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(indexed) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: palette,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
