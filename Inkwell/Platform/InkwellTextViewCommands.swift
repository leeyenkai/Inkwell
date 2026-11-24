import AppKit
import InkwellKit
import SwiftUI

/// The editor's commands beyond inline formatting: links, lists, lines, code blocks, zoom and the formatting state.
/// Every text change goes through `apply`, so each command is one undo step.
extension InkwellTextView {
    // MARK: Formatting state

    /// Coalesces updates to after the current event, so typing pays nothing for the formatting bar.
    func scheduleFormatUpdate() {
        guard formatState != nil, !formatUpdatePending else { return }
        formatUpdatePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.formatUpdatePending = false
            self.updateFormatState()
        }
    }

    func updateFormatState() {
        guard let formatState, !hasMarkedText() else { return }
        let selection = selectedRange()
        let ns = string as NSString
        guard NSMaxRange(selection) <= ns.length else { return }
        let state = sourceMode ? FormatState() : FormatState.at(string, selection: selection)
        if formatState.state != state { formatState.state = state }
        var words = 0, characters = 0
        if selection.length > 0 {
            let selected = ns.substring(with: selection)
            words = ContentChecks.wordCount(selected)
            characters = selected.count
        }
        if formatState.selectedWords != words { formatState.selectedWords = words }
        if formatState.selectedCharacters != characters { formatState.selectedCharacters = characters }
    }

    // MARK: Clicks

    /// The character under a point, only when the point is on that character's glyph rather than beside the line.
    func characterIndex(onGlyphAt point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -2)
        guard rect.contains(inContainer) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// The rectangle of a range of characters, in this view.
    func rect(for range: NSRange) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let length = (string as NSString).length
        let clipped = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        var rect: NSRect
        if clipped.length == 0 {
            let glyph = layout.glyphIndexForCharacter(at: clipped.location)
            rect = glyph < layout.numberOfGlyphs
                ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                : layout.extraLineFragmentRect
            let point = glyph < layout.numberOfGlyphs ? layout.location(forGlyphAt: glyph).x : 0
            rect = NSRect(x: rect.minX + point, y: rect.minY, width: 1, height: rect.height)
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: clipped, actualCharacterRange: nil)
            // The first line of the range only, so the popover points at where the selection starts.
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: container).intersection(first)
            if rect.isEmpty { rect = layout.boundingRect(forGlyphRange: glyphs, in: container) }
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// A click on a checklist box ticks it; ⌘-click on a link opens it. Returns false for an ordinary click.
    func handleClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, !hasMarkedText() else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(onGlyphAt: point) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let link = MarkdownLink.find(in: string, at: NSRange(location: index, length: 0)) {
            follow(link.url)
            return true
        }
        guard flags.isEmpty, !sourceMode, let box = EditorCommands.checkbox(in: string, line: index), NSLocationInRange(index, box) else {
            return false
        }
        window?.makeFirstResponder(self)
        toggleCheckbox(atLine: index)
        return true
    }

    func toggleCheckbox(atLine location: Int) {
        guard let result = EditorCommands.toggleCheckbox(string, line: location, selection: selectedRange()) else { return }
        apply(result, scroll: false)
    }

    // MARK: Context menu

    func addEditorItems(to menu: NSMenu, at index: Int) {
        var items: [NSMenuItem] = []
        func item(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            return item
        }
        let selection = selectedRange()
        let onLink = MarkdownLink.find(in: string, at: NSRange(location: index, length: 0))
            ?? (NSLocationInRange(index, selection) ? MarkdownLink.find(in: string, at: selection) : nil)
        if let link = onLink {
            items += [
                item(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)), link.url),
                item(String(localized: "Edit Link…"), #selector(editLinkFromMenu(_:)), link.range.location),
                item(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)), link.url),
                item(String(localized: "Remove Link"), #selector(removeLinkFromMenu(_:)), link.range.location),
            ]
        } else if selection.length > 0 || !sourceMode {
            items.append(item(selection.length > 0 ? String(localized: "Add Link…") : String(localized: "Insert Link…"),
                              #selector(editLinkFromMenu(_:)), selection.length > 0 ? nil : index))
        }
        if !sourceMode, let block = EditorCommands.codeBlock(in: string, at: index) {
            let languages = NSMenu(title: String(localized: "Code Language"))
            for name in [""] + EditorCommands.codeLanguages {
                let title = name.isEmpty ? String(localized: "None") : name
                let entry = item(title, #selector(codeLanguageFromMenu(_:)), [name, block.range.location])
                entry.state = block.language == name ? .on : .off
                languages.addItem(entry)
            }
            let parent = NSMenuItem(title: String(localized: "Code Language"), action: nil, keyEquivalent: "")
            parent.submenu = languages
            items.append(parent)
        }
        guard !items.isEmpty else { return }
        items.append(.separator())
        for (offset, entry) in items.enumerated() { menu.insertItem(entry, at: offset) }
    }

    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? String { follow(url) }
    }

    @objc func editLinkFromMenu(_ sender: NSMenuItem) {
        if let location = sender.representedObject as? Int { setSelectedRange(NSRange(location: location + 1, length: 0)) }
        showLinkPopover()
    }

    @objc func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func removeLinkFromMenu(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? Int,
              let link = MarkdownLink.find(in: string, at: NSRange(location: location + 1, length: 0)) else { return }
        apply(Formatting.removeLink(string, link: link))
    }

    @objc func codeLanguageFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let name = info.first as? String, let location = info.last as? Int else {
            return
        }
        setSelectedRange(NSRange(location: location, length: 0))
        setCodeLanguage(name)
    }

    // MARK: Links

    /// Opens a link: a heading in this post scrolls to it; anything else goes to the app.
    func follow(_ url: String) {
        if case let .anchor(id)? = LinkDestination(url) {
            revealAnchor(id)
        } else {
            onOpenLink?(url)
        }
    }

    /// Scrolls to the heading with this kramdown id and puts the cursor at its start.
    func revealAnchor(_ id: String) {
        let headings = HeadingAnchor.list(in: string)
        guard let index = headings.firstIndex(where: { $0.anchor == id }) else { return NSSound.beep() }
        let lines = MarkdownScanner.scan(string).compactMap { span -> NSRange? in
            if case .heading = span.style { return span.range }
            return nil
        }
        guard index < lines.count else { return }
        let range = lines[index]
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
    }

    /// The link popover: search the site's posts and pages and this post's headings, or type or paste an address.
    /// With the cursor in a link, it shows where the link goes with Open, Edit and Remove Link.
    func showLinkPopover() {
        linkPopover?.close()
        let selection = selectedRange()
        let ns = string as NSString
        guard NSMaxRange(selection) <= ns.length else { return }
        let link = MarkdownLink.find(in: string, at: selection)
        let selected = selection.length > 0 && selection.length < 200 ? ns.substring(with: selection) : ""
        let clipboard = NSPasteboard.general.string(forType: .string).flatMap { $0.count < 2000 ? $0 : nil }
        let model = LinkPopoverModel(link: link, entries: linkEntries?() ?? [], headings: sourceMode ? [] : HeadingAnchor.list(in: string),
                                     context: selected.contains("\n") ? "" : selected, clipboard: clipboard)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: LinkPopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        let close = { [weak self, weak popover] in
            popover?.close()
            self?.window?.makeFirstResponder(self)
        }
        model.onClose = close
        model.onChoose = { [weak self] suggestion in
            self?.applyLink(url: suggestion.url, title: suggestion.title, selection: selection)
            close()
        }
        model.onOpen = { [weak self] in
            close()
            if let url = link?.url { self?.follow(url) }
        }
        model.onRemove = { [weak self] in
            close()
            guard let self, let current = MarkdownLink.find(in: string, at: selection) else { return }
            apply(Formatting.removeLink(string, link: current))
        }
        linkPopover = popover
        popover.show(relativeTo: rect(for: link?.textRange ?? selection), of: self, preferredEdge: .maxY)
    }

    /// Links the selection (or the link around it) to `url`, or inserts `title` as a link when nothing is selected.
    /// The link popover and the self-test both come through here.
    func applyLink(url: String, title: String, selection: NSRange) {
        guard NSMaxRange(selection) <= (string as NSString).length else { return }
        apply(Formatting.setLink(string, selection: selection, url: url, title: title))
    }

    // MARK: Lists, lines and blocks

    func setList(_ kind: FormatState.List) { apply(EditorCommands.list(kind, in: string, selection: selectedRange())) }

    func moveLines(up: Bool) {
        guard let result = EditorCommands.moveLines(string, selection: selectedRange(), up: up) else { return NSSound.beep() }
        apply(result)
    }

    func indentLines(outdent: Bool) {
        guard let result = EditorCommands.indent(string, selection: selectedRange(), outdent: outdent) else { return NSSound.beep() }
        apply(result)
    }

    func clearFormatting() {
        guard let result = EditorCommands.clearFormatting(string, selection: selectedRange()) else { return NSSound.beep() }
        apply(result)
    }

    func setTextStyle(_ style: TextStyle) {
        let inCode = EditorCommands.codeBlock(in: string, at: selectedRange().location) != nil
        switch style {
        case .title: heading(1)
        case .heading: heading(2)
        case .subheading: heading(3)
        case .body: inCode ? apply(EditorCommands.toggleCodeBlock(string, selection: selectedRange())) : heading(0)
        case .monospaced: if !inCode { apply(EditorCommands.toggleCodeBlock(string, selection: selectedRange())) }
        }
    }

    func setCodeLanguage(_ language: String) {
        guard let block = EditorCommands.codeBlock(in: string, at: selectedRange().location) else { return NSSound.beep() }
        apply(EditorCommands.setCodeLanguage(string, block: block, language: language, selection: selectedRange()), scroll: false)
    }

    /// The Insert button: the hook when someone has set one, otherwise the insert menu at the cursor.
    func insertElement() {
        let location = selectedRange().location
        if let onInsertElement {
            onInsertElement(location)
        } else {
            showInsertMenu(at: location)
        }
    }

    /// A block chosen from the Insert menu rather than typed after `/`: on an empty line it takes the line, otherwise
    /// it goes in a new paragraph after this one. One edit, so one undo step.
    func insertBlockFromMenu(_ block: SmartTyping.Block, at location: Int) {
        if block == .table {
            onEditTable?(nil, .blank(), location)
            return
        }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        var end = NSMaxRange(line)
        if end > line.location, ns.character(at: end - 1) == 10 { end -= 1 }
        let content = ns.substring(with: NSRange(location: line.location, length: end - line.location))
        let empty = content.trimmingCharacters(in: .whitespaces).isEmpty
        let slash = empty ? TextEdit(NSRange(location: line.location, length: end - line.location), "/")
            : TextEdit(NSRange(location: end, length: 0), "\n\n/")
        let slashAt = empty ? line.location : end + 2
        let withSlash = FormattingResult(edits: [slash], selection: NSRange(location: slashAt, length: 0)).applied(to: string)
        let result = SmartTyping.insert(block, in: withSlash, slashAt: slashAt)
        apply(FormattingResult(edits: [slash] + result.edits, selection: result.selection))
    }

    // MARK: Zoom

    static let zoomSteps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    /// Zooms the text for this session; `step` 0 goes back to actual size.
    func zoom(step: Int) {
        let steps = Self.zoomSteps
        let current = steps.firstIndex { $0 >= MarkdownStyler.zoom - 0.001 } ?? 2
        let next = step == 0 ? 2 : min(max(0, current + step), steps.count - 1)
        guard steps[next] != MarkdownStyler.zoom else { return NSSound.beep() }
        MarkdownStyler.zoom = steps[next]
        restyle()
    }
}
