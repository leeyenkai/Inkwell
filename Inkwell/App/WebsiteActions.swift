import Foundation
import InkwellKit

/// Hand-built websites (SPEC §4.12, W4): the menu copied into every page, and the optional move to Jekyll.
extension AppModel {
    /// Files whose menu can be edited: HTML pages, and on a Jekyll site the includes that hold a `<nav>`.
    var menuSources: [MenuSource] {
        guard let site else { return [] }
        var sources = site.documents.filter(\.editsAsHTML).sorted { $0.relativePath < $1.relativePath }.map {
            MenuSource(title: $0.title, path: $0.relativePath, linksFrom: $0.relativePath)
        }
        let includes = site.root.appending(path: "_includes")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: includes.path)) ?? []).sorted() where name.hasSuffix(".html") {
            guard let text = try? String(contentsOf: includes.appending(path: name), encoding: .utf8), HTMLMenu.find(in: text) != nil else { continue }
            // An include is copied into pages; its addresses are written as from the site's top folder.
            sources.append(MenuSource(title: name, path: "_includes/\(name)", linksFrom: "index.html"))
        }
        return sources
    }

    struct MenuSource: Hashable {
        var title: String
        var path: String
        /// The page its relative addresses are read from.
        var linksFrom: String
    }

    /// The current text of a site file: the open editor's, which may not be saved yet, or the file's.
    func currentText(of path: String) -> String? {
        if let editor, editor.document.relativePath == path { return editor.fullText }
        return site.flatMap { try? String(contentsOf: $0.root.appending(path: path), encoding: .utf8) }
    }

    /// The other sources whose menu leads to the same places as `source`'s, and those with a different menu.
    func menuMatches(for source: MenuSource, menu: HTMLMenu) -> (same: [MenuSource], different: [MenuSource]) {
        let targets = menu.targets(onPage: source.linksFrom)
        var same: [MenuSource] = [], different: [MenuSource] = []
        for other in menuSources where other.path != source.path {
            guard let text = currentText(of: other.path), let theirs = HTMLMenu.find(in: text) else { continue }
            if theirs.targets(onPage: other.linksFrom) == targets { same.append(other) } else { different.append(other) }
        }
        return (same, different)
    }

    /// Makes the menu `entries` on `source` and on each of `others`, rewriting only the items that changed.
    func applyMenu(_ entries: [HTMLMenu.Entry], from menu: HTMLMenu, on source: MenuSource, and others: [MenuSource]) {
        guard let site else { return }
        for target in [source] + others {
            guard let text = currentText(of: target.path),
                  let updated = HTMLMenu.applying(entries, from: menu, referencePage: source.linksFrom, to: text, page: target.linksFrom),
                  updated != text else { continue }
            if let editor, editor.document.relativePath == target.path {
                editor.setFullText(updated)
            } else {
                do {
                    try ContentEdit(path: target.path, newText: updated).apply(to: site.root)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        refreshChanges()
    }

    // MARK: Moving to Jekyll

    /// What moving the open site to Jekyll would change.
    func jekyllAdoptionPlan() -> JekyllAdoption.Plan? {
        guard let site else { return nil }
        editor?.saveNow()
        var pages: [String: String] = [:]
        for doc in site.documents where doc.isStatic {
            if let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) { pages[doc.relativePath] = text }
        }
        return JekyllAdoption.plan(root: site.root, pages: pages)
    }

    /// Writes the plan into the site, then shows every change for review. Nothing is published until the person does.
    func adoptJekyll(_ plan: JekyllAdoption.Plan) {
        guard let site, backend != nil else { return }
        settleEditor()
        editor?.retire()
        editor = nil
        selectedDocumentID = nil
        let edits = plan.writes.map { ContentEdit(path: $0.key, newText: $0.value) } + plan.removals.map { ContentEdit(path: $0, newText: nil) }
        do {
            for edit in edits { try edit.apply(to: site.root) }
        } catch {
            errorMessage = error.localizedDescription
        }
        // The site's kind follows its files from now on.
        if chosenKind?.servesFilesAsIs == true, let key = backend?.draftKey { UserDefaults.standard.removeObject(forKey: "siteKind:\(key)") }
        reloadSite()
        reloadDesign()
        showChanges = true
    }
}
