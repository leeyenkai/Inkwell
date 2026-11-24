import AppKit
import InkwellKit

/// Links in the editor: what can be linked to, and opening a link in the editor or the browser.
extension AppModel {
    /// The site's posts and pages, newest first, for the link popover. The post being edited is left out.
    var linkEntries: [LinkSearch.Entry] {
        guard let site else { return [] }
        let current = editor?.document.relativePath
        return site.documents.filter { $0.relativePath != current }.map { doc in
            let section = site.section(doc.sectionID)?.label ?? (doc.isPage ? String(localized: "Page") : "")
            let date = doc.date.map { $0.formatted(date: .abbreviated, time: .omitted) }
            let detail = [section, date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return LinkSearch.Entry(title: doc.title, url: doc.url, detail: detail, date: doc.date)
        }
    }

    /// The post or page a site path such as `/notes/estonia/` leads to, with or without the site's base path,
    /// a trailing slash or `.html`.
    func document(forLink path: String) -> SiteDocument? {
        guard let site else { return nil }
        func normal(_ p: String) -> String {
            var s = p.removingPercentEncoding ?? p
            let base = site.config.baseurl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !base.isEmpty, s.hasPrefix("/" + base + "/") { s.removeFirst(base.count + 1) }
            for suffix in ["/index.html", ".html", "/"] where s.hasSuffix(suffix) && s.count > suffix.count { s.removeLast(suffix.count) }
            return s.lowercased()
        }
        let target = normal(path)
        return site.documents.first { normal($0.url) == target } ?? drafts.first { normal($0.url) == target }
    }

    /// Opens a link from the editor: a post of the site in the editor, anything else on the web.
    func openLink(_ target: String) {
        switch LinkDestination(target) {
        case let .site(path)?:
            if let doc = document(forLink: path) {
                if case .section = sidebarSelection, site?.section(doc.sectionID) != nil { sidebarSelection = .section(doc.sectionID) }
                if case .drafts = sidebarSelection, doc.origin != .localDraft { sidebarSelection = .section(doc.sectionID) }
                select(doc.id)
            } else if let base = pagesURL ?? site.flatMap({ URL(string: $0.config.url + $0.config.baseurl) }), !base.absoluteString.isEmpty,
                      let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) {
                NSWorkspace.shared.open(url)
            } else {
                errorMessage = String(localized: "No post or page of this site has the address \(path).")
            }
        case let .web(url)?:
            NSWorkspace.shared.open(url)
        case let .anchor(id)?:
            textView?.revealAnchor(id)
        case nil:
            errorMessage = String(localized: "Inkwell cannot open the link \(target).")
        }
    }
}
