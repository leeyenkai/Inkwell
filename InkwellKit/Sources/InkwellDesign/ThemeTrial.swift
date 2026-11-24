import Foundation
import InkwellCore

/// Copies of a site with a theme applied, so a theme can be previewed without writing to the site's own folder.
public enum ThemeTrial {
    /// History, build output and installed gems, which a preview does not need.
    static let skipped: Set<String> = [".git", "_site", ".jekyll-cache", ".sass-cache", "node_modules", "vendor", ".bundle", ".DS_Store"]

    public enum Failure: Error, LocalizedError {
        case sameFolder
        public var errorDescription: String? { localized("A theme preview cannot be made in the site’s own folder.") }
    }

    /// Copies a site's files into `destination`, replacing whatever is there. APFS clones the files, so this is quick.
    public static func copySite(from source: URL, to destination: URL) throws {
        // Never inside the site (it would copy itself) and never around it (clearing the destination would delete the site).
        let from = source.standardizedFileURL.resolvingSymlinksInPath().path
        let to = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard from != to, !to.hasPrefix(from + "/"), !from.hasPrefix(to + "/") else { throw Failure.sameFolder }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items where !skipped.contains(item.lastPathComponent) {
            try fm.copyItem(at: item, to: destination.appending(path: item.lastPathComponent))
        }
    }

    /// A copy of `site` at `destination` with `theme` applied, as it would look after choosing the theme.
    @discardableResult
    public static func make(theme: ThemeManifest, site: URL, at destination: URL) throws -> AdoptionPlan {
        try copySite(from: site, to: destination)
        let plan = ThemeApplier.plan(theme: theme, siteRoot: destination)
        try plan.apply(to: destination)
        return plan
    }

    /// Addresses worth looking at in a site: the home page, the newest post and a page other than the home page.
    public static func samplePages(in site: Site) -> (home: String, post: String?, page: String?) {
        let posts = site.documents.filter { !$0.isPage && $0.origin == .repository && $0.publishedFlag }
        let post = posts.max { ($0.date ?? .distantPast, $0.relativePath) < ($1.date ?? .distantPast, $1.relativePath) }
        let pages = site.documents.filter {
            $0.isPage && $0.url != "/" && !$0.url.hasSuffix("404.html") && $0.relativePath.hasSuffix(".md")
        }
        let page = pages.first { $0.relativePath.lowercased().hasPrefix("about") } ?? pages.min { $0.relativePath < $1.relativePath }
        return ("/", post?.url, page?.url)
    }
}
