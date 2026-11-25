import AppKit
import InkwellKit

/// Page elements in the editor: inserting one, editing its settings in a form, and the site files they need.
extension AppModel {
    struct ElementEdit: Identifiable {
        let id = UUID()
        var span: ElementSpan
        /// The element's text when the form opened, to make sure the same element is still there when it closes.
        var original: String
        var inner: String
    }

    /// Writes the element kit into the site when it is missing or an older version Inkwell wrote, and loads it on themes
    /// Inkwell did not write. The site's own files at kit paths are never replaced. The files become unpublished changes
    /// and go out with the first post that uses an element.
    func ensureElementKit() {
        guard let site else { return }
        var edits = ElementKit.changes(siteRoot: site.root).map { ContentEdit(path: $0.path, newText: $0.newText) }
        if !ElementKit.isLoaded(siteRoot: site.root) {
            edits += SiteHealth.headInsertion(root: site.root, tag: ElementKit.headTags)
        }
        guard !edits.isEmpty else { return }
        do {
            for edit in edits { try edit.apply(to: site.root) }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshChanges()
    }

    /// Inserts a new element at the cursor. Elements made of pictures, places or cards open their form straight away.
    func insertElement(_ kind: PageElement) {
        guard let textView, let site else { return }
        ensureElementKit()
        let collection = site.sections.first { $0.collectionName == "posts" }?.collectionName
            ?? site.sections.first { $0.collectionName != nil }?.collectionName ?? "posts"
        let location = textView.selectedRange().location
        textView.apply(PageElements.insertion(kind.template(collection: collection), in: textView.string, at: location))
        if [.gallery, .slideshow, .map, .cards, .button, .hero].contains(kind) {
            editElement(at: textView.selectedRange().location + 1)
        }
    }

    /// Opens the form for the element at (or around) `location`.
    func editElement(at location: Int? = nil) {
        guard let textView else { return }
        let text = textView.string
        guard let span = PageElements.element(in: text, at: location ?? textView.selectedRange().location) else {
            errorMessage = String(localized: "Put the cursor in a page element to edit it.")
            return
        }
        let ns = text as NSString
        elementEdit = ElementEdit(span: span, original: ns.substring(with: span.range),
                                  inner: span.innerRange.map { ns.substring(with: $0) } ?? "")
    }

    func finishElementEdit(attributes: [String: String], inner: String?) {
        guard let edit = elementEdit, let textView else { return }
        elementEdit = nil
        let ns = textView.string as NSString
        guard NSMaxRange(edit.span.range) <= ns.length, ns.substring(with: edit.span.range) == edit.original else {
            errorMessage = String(localized: "The element changed while its settings were open, so the changes were not applied.")
            return
        }
        textView.apply(PageElements.update(edit.span, in: textView.string, attributes: attributes, inner: inner))
        refreshChanges()
    }

    /// Pictures chosen in an element's form: resized, cleaned and copied into the site like any other image.
    func importPictures(_ urls: [URL]) async -> [String] {
        guard let site else { return [] }
        let slug = editor.map { Filename.parse($0.document.filename).slug } ?? "image"
        let root = site.root
        let images = await Task.detached {
            urls.compactMap { try? ImageImport.app.importImage(at: $0, siteRoot: root, slug: slug == "untitled" ? "image" : slug) }
        }.value
        refreshChanges()
        return images.map(\.sitePath)
    }

    /// Collections the recent-posts and archive elements can show.
    var elementCollections: [String] {
        site?.sections.compactMap(\.collectionName) ?? ["posts"]
    }

    /// Posts and pages to link to from buttons and cards: title and site address.
    var linkTargets: [(title: String, url: String)] {
        guard let site else { return [] }
        return site.documents.filter { !$0.url.isEmpty }.map { ($0.title.isEmpty ? $0.filename : $0.title, $0.url) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Page templates

    func createPage(title: String, template: PageTemplate, addToMenu: Bool) {
        guard let site else { return }
        let collection = site.sections.first { $0.collectionName == "posts" }?.collectionName
            ?? site.sections.first { $0.collectionName != nil }?.collectionName ?? "posts"
        let body = template.body(collection: collection)
        if template != .blank { ensureElementKit() }
        createPage(title: title, body: body, addToMenu: addToMenu, layout: template.layout, fields: template.fields)
    }
}
