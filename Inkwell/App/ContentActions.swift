import AppKit
import InkwellKit

extension AppModel {
    // MARK: Rename and move

    /// Saves a new title, address and section for a post. A published post's file moves in one change, with its old
    /// address kept working and links in other posts updated; a draft simply follows.
    func applyMove(_ doc: SiteDocument, title: String, slug: String, sectionID: String, keepOldAddress: Bool) {
        guard let site, let backend else { return }
        if editor?.document.id == doc.id { editor?.saveNow() }
        let cleanSlug = Slug.make(slug.isEmpty ? title : slug)
        var text = (try? String(contentsOf: doc.fileURL, encoding: .utf8)) ?? ""
        var front = FrontMatterDocument(text: text)
        if title != (front.value("title")?.string ?? doc.title) {
            front.set("title", raw: YAMLFormat.quoted(title), order: ["title"])
            text = front.text
        }
        let parts = Filename.parse(doc.filename)
        let ext = parts.ext.isEmpty ? "md" : parts.ext
        let filename = parts.dateText.map { "\($0)-\(cleanSlug).\(ext)" } ?? "\(cleanSlug).\(ext)"
        let collection = site.section(sectionID)?.collectionName

        if doc.origin == .localDraft {
            guard let draftStore, let collection else { return }
            let target = draftStore.url(collection: collection, filename: filename)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .atomic)
                if target.standardizedFileURL != doc.fileURL.standardizedFileURL { try FileManager.default.removeItem(at: doc.fileURL) }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            retireEditor(for: doc)
            reloadDrafts()
            sidebarSelection = .section(sectionID)
            if let moved = drafts.first(where: { $0.fileURL.standardizedFileURL == target.standardizedFileURL }) { select(moved.id) }
            return
        }

        let folder = (doc.relativePath as NSString).deletingLastPathComponent
        let newPath = collection.map { "_\($0)/\(filename)" } ?? (folder.isEmpty ? filename : "\(folder)/\(filename)")
        if newPath == doc.relativePath {
            try? Data(text.utf8).write(to: doc.fileURL, options: .atomic)
            editor?.reloadIfChangedOnDisk()
            reloadSite()
            return
        }
        guard !FileManager.default.fileExists(atPath: site.root.appending(path: newPath).path) else {
            errorMessage = "\(newPath) already exists. Choose another address."
            return
        }
        let published = status(of: doc) != .notPublished
        let config = try? String(contentsOf: site.root.appending(path: "_config.yml"), encoding: .utf8)
        let plan = MovePlanner.plan(document: doc, text: text, newPath: newPath, keepOldAddress: keepOldAddress && published, site: site,
                                    configText: config)
        retireEditor(for: doc)
        do {
            for edit in plan.edits { try edit.apply(to: site.root) }
        } catch {
            errorMessage = "The post could not be moved: \(error.localizedDescription)"
            return
        }
        sidebarSelection = sectionID == doc.sectionID ? sidebarSelection : .section(sectionID)
        didPublish(selecting: newPath)
        guard published else { return }
        let links = plan.updatedLinks.count
        publishSheet = PublishSession.changes(paths: plan.edits.map(\.path), message: "Move: \(title)", backend: backend, model: self,
                                              heading: "Move “\(title)”" + (links > 0 ? " and update \(links) link\(links == 1 ? "" : "s")" : ""),
                                              selecting: newPath)
    }

    /// Sections a post can move to: collections only (pages stay pages).
    var movableSections: [SiteSection] { site?.sections.filter { $0.collectionName != nil } ?? [] }

    // MARK: Duplicate and new page

    func duplicate(_ doc: SiteDocument) {
        guard let site, let draftStore, let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { return }
        var front = FrontMatterDocument(text: text)
        let title = "Copy of \(front.value("title")?.string ?? doc.title)"
        front.set("title", raw: YAMLFormat.quoted(title), order: ["title"])
        front.set("redirect_from", raw: nil)
        if let collection = doc.relativePath.hasPrefix("_") ? String(doc.relativePath.dropFirst().prefix { $0 != "/" }) : nil {
            let today = Date()
            if front.value("date") != nil { front.set("date", raw: YAMLFormat.date(today, timeZone: site.config.timeZone)) }
            do {
                let url = try draftStore.create(collection: collection, title: title, date: today, text: front.text, siteRoot: site.root)
                reloadDrafts()
                if let copy = drafts.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) { select(copy.id) }
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            createPage(title: title, body: front.body, addToMenu: false)
        }
    }

    /// A new standalone page (About, Now, Contact) in the site, unpublished until you publish it.
    func createPage(title: String, body: String = "\n", addToMenu: Bool) {
        guard let site else { return }
        var name = Slug.make(title)
        var n = 2
        while FileManager.default.fileExists(atPath: site.root.appending(path: "\(name).md").path) {
            name = "\(Slug.make(title))-\(n)"
            n += 1
        }
        let hasPageLayout = [site.root, themeRoot].compactMap { $0 }
            .contains { FileManager.default.fileExists(atPath: $0.appending(path: "_layouts/page.html").path) }
        let text = FrontMatterDocument(fields: [("layout", hasPageLayout ? "page" : "default"), ("title", YAMLFormat.quoted(title))], body: body).text
        let path = "\(name).md"
        do {
            try ContentEdit(path: path, newText: text).apply(to: site.root)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if addToMenu, let design {
            design.saveNavigation(design.navigation.entries + [NavigationEntry(title: title, url: "/\(name)")])
        }
        sidebarSelection = .section("pages")
        didPublish(selecting: path)
    }

    // MARK: Editor actions

    func slashAction(_ action: String, at location: Int) {
        switch action {
        case "image":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { importImages(panel.urls, at: location) }
        case "embed":
            let alert = NSAlert()
            alert.messageText = "Embed a video"
            alert.informativeText = "Paste a YouTube or Vimeo address."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "https://www.youtube.com/watch?v=…"
            field.stringValue = NSPasteboard.general.string(forType: .string) ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "Embed")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let html = SmartTyping.embed(for: field.stringValue) {
                textView?.insertBlock(html, at: location)
            } else {
                errorMessage = "That is not a YouTube or Vimeo address Inkwell can embed."
            }
        default:
            break
        }
    }

    // MARK: Tags

    var allTags: [(name: String, count: Int)] {
        tagIndex.map { ($0.key, $0.value.count) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func documents(tagged tag: String) -> [SiteDocument] {
        let ids = Set(tagIndex[tag] ?? [])
        return allDocuments.filter { ids.contains($0.id) }
    }

    /// Renames a tag (or merges it into another, or removes it when `newName` is nil) in every post and draft using it.
    func renameTag(_ tag: String, to newName: String?) {
        editor?.saveNow()
        var changed = 0
        for doc in documents(tagged: tag) {
            guard let text = try? String(contentsOf: doc.fileURL, encoding: .utf8), let updated = TagIndex.rename(tag, to: newName, in: text) else { continue }
            do {
                try Data(updated.utf8).write(to: doc.fileURL, options: .atomic)
                changed += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        editor?.reloadIfChangedOnDisk()
        selectedTag = changed > 0 ? newName : tag
        reloadSite()
    }
}
