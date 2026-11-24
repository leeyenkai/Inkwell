import AppKit
import InkwellKit
import SwiftUI
import UniformTypeIdentifiers

/// The writing surface: a plain-text view over the Markdown source, styled live. Styling is attributes only,
/// so the file always holds exactly what was typed.
final class InkwellTextView: NSTextView {
    var onImportImages: (([URL], Int) -> Void)?
    /// Called with the location of a typed `[[`, to pick a post to link to.
    var onLinkPicker: ((Int) -> Void)?
    /// Called for slash-menu items the view cannot do alone (image, embed).
    var onSlashAction: ((String, Int) -> Void)?
    var sourceMode = false
    /// Hide Markdown markers on every line except the one being edited.
    var hidesSyntax = true
    private(set) var liquidRanges: [NSRange] = []
    private var styledParagraph: NSRange?
    static let columnWidth: CGFloat = 700

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, (newSize.width - Self.columnWidth) / 2)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: 8) }
    }

    func restyle() {
        guard let storage = textStorage else { return }
        let active = activeParagraph
        styledParagraph = active
        liquidRanges = MarkdownStyler.apply(to: storage, source: sourceMode, activeRange: hidesSyntax && !sourceMode ? active : nil)
        typingAttributes = MarkdownStyler.baseAttributes(source: sourceMode)
    }

    var activeParagraph: NSRange {
        let ns = string as NSString
        let selection = selectedRange()
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(selection.location, ns.length)
        return ns.paragraphRange(for: NSRange(location: start, length: min(selection.length, ns.length - start)))
    }

    /// Markers show again on the line the cursor moves to, and hide on the line it left.
    func selectionMoved() {
        let previous = styledParagraph ?? NSRange(location: NSNotFound, length: 0)
        guard hidesSyntax, !sourceMode, !hasMarkedText(), !NSEqualRanges(activeParagraph, previous) else { return }
        restyle()
    }

    // MARK: Smart typing

    override func insertNewline(_ sender: Any?) {
        if !sourceMode, selectedRange().length == 0, let result = SmartTyping.newline(in: string, at: selectedRange().location) {
            apply(result)
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if !sourceMode, let result = SmartTyping.indent(in: string, selection: selectedRange(), outdent: false) {
            apply(result)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if !sourceMode, let result = SmartTyping.indent(in: string, selection: selectedRange(), outdent: true) {
            apply(result)
            return
        }
        super.insertBacktab(sender)
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        guard !sourceMode, let typed = text as? String else { return }
        let ns = string as NSString
        let cursor = selectedRange().location
        if typed == "/", cursor >= 1 {
            let line = ns.lineRange(for: NSRange(location: cursor - 1, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: cursor - 1 - line.location))
            if before.trimmingCharacters(in: .whitespaces).isEmpty { showSlashMenu(slashAt: cursor - 1) }
        } else if typed == "[", cursor >= 2, ns.substring(with: NSRange(location: cursor - 2, length: 2)) == "[[" {
            onLinkPicker?(cursor - 2)
        }
    }

    func showSlashMenu(slashAt location: Int) {
        let menu = NSMenu(title: "Insert")
        for block in SmartTyping.Block.allCases {
            let item = NSMenuItem(title: block.title, action: #selector(slashBlock(_:)), keyEquivalent: "")
            item.representedObject = [block.rawValue, location] as [Any]
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, key) in [("Image…", "image"), ("Link to a Post…", "link"), ("Embed a Video…", "embed"), ("Footnote", "footnote")] {
            let item = NSMenuItem(title: title, action: #selector(slashAction(_:)), keyEquivalent: "")
            item.representedObject = [key, location] as [Any]
            item.target = self
            menu.addItem(item)
        }
        guard let layout = layoutManager, let container = textContainer else {
            menu.popUp(positioning: nil, at: .zero, in: self)
            return
        }
        let glyph = layout.glyphIndexForCharacter(at: location)
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y + rect.height + 4
        menu.popUp(positioning: nil, at: rect.origin, in: self)
    }

    @objc func slashBlock(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let raw = info.first as? String, let block = SmartTyping.Block(rawValue: raw),
              let location = info.last as? Int, location < (string as NSString).length else { return }
        apply(SmartTyping.insert(block, in: string, slashAt: location))
    }

    @objc func slashAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let key = info.first as? String, let location = info.last as? Int,
              location < (string as NSString).length else { return }
        // Remove the typed slash first.
        apply(FormattingResult(edits: [TextEdit(NSRange(location: location, length: 1), "")], selection: NSRange(location: location, length: 0)))
        switch key {
        case "footnote": footnote()
        case "link": onLinkPicker?(location)
        default: onSlashAction?(key, location)
        }
    }

    /// Replaces the `[[` typed at `location` with a link.
    func insertLink(title: String, url: String, replacing location: Int) {
        let ns = string as NSString
        let length = location + 2 <= ns.length && ns.substring(with: NSRange(location: location, length: 2)) == "[[" ? 2 : 0
        let link = "[\(title)](\(url))"
        apply(FormattingResult(edits: [TextEdit(NSRange(location: location, length: length), link)],
                               selection: NSRange(location: location + (link as NSString).length, length: 0)))
    }

    // Liquid tags behave as one piece: they can be selected and deleted whole, but not edited from inside.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let undoing = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if !sourceMode, !undoing {
            for chip in liquidRanges {
                let inside = affectedCharRange.location > chip.location && affectedCharRange.location < NSMaxRange(chip)
                let overlaps = NSIntersectionRange(chip, affectedCharRange).length > 0
                let coversChip = NSEqualRanges(NSUnionRange(chip, affectedCharRange), affectedCharRange)
                if (inside || overlaps) && !coversChip {
                    NSSound.beep()
                    return false
                }
            }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: Formatting

    func apply(_ result: FormattingResult) {
        guard let storage = textStorage else { return }
        undoManager?.beginUndoGrouping()
        for edit in result.edits where super.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(result.selection)
        scrollRangeToVisible(result.selection)
    }

    func replaceAll(with text: String, selection: NSRange) {
        apply(FormattingResult(edits: [TextEdit(NSRange(location: 0, length: (string as NSString).length), text)], selection: selection))
    }

    func toggle(_ open: String, _ close: String? = nil) {
        apply(Formatting.toggle(string, selection: selectedRange(), open: open, close: close))
    }

    func heading(_ level: Int) { apply(Formatting.heading(string, selection: selectedRange(), level: level)) }

    func prefixLines(_ prefix: String) { apply(Formatting.linePrefix(string, selection: selectedRange(), prefix: prefix)) }

    func footnote() {
        let result = Formatting.footnote(string, at: selectedRange().location)
        replaceAll(with: result.text, selection: result.selection)
    }

    func divider() { apply(Formatting.divider(string, at: selectedRange().location)) }

    func link() {
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = Self.looksLikeURL(clipboard) ? clipboard : "https://"
        var result = Formatting.link(string, selection: selectedRange(), url: url)
        if url == "https://", let edit = result.edits.first {
            let start = edit.range.location + (edit.replacement as NSString).length - 1 - (url as NSString).length
            result.selection = NSRange(location: start, length: (url as NSString).length)
        }
        apply(result)
    }

    func insertBlock(_ markdown: String, at location: Int) {
        let ns = string as NSString
        let at = min(location, ns.length)
        let lineStart = at == 0 || ns.character(at: at - 1) == 10
        let insert = (lineStart ? "" : "\n\n") + markdown + "\n"
        apply(FormattingResult(edits: [TextEdit(NSRange(location: at, length: 0), insert)],
                               selection: NSRange(location: at + (insert as NSString).length, length: 0)))
    }

    static func looksLikeURL(_ s: String) -> Bool {
        guard !s.contains(" "), let url = URL(string: s), let scheme = url.scheme else { return false }
        return ["http", "https", "mailto"].contains(scheme) && (url.host != nil || scheme == "mailto")
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let images = imageFiles(from: board) {
            onImportImages?(images, selectedRange().location)
            return
        }
        if let pasted = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           selectedRange().length > 0, Self.looksLikeURL(pasted) {
            apply(Formatting.link(string, selection: selectedRange(), url: pasted))
            return
        }
        // Rich text from a web page or document comes in as Markdown with its structure (headings, lists, links) kept.
        if !sourceMode, let html = board.string(forType: .html),
           html.range(of: #"<(h[1-6]|li|a |strong|b>|em|i>|blockquote|p[ >])"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let markdown = HTMLToMarkdown.convert(html)
            if !markdown.isEmpty {
                insertText(markdown, replacementRange: selectedRange())
                return
            }
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let images = imageFiles(from: sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            onImportImages?(images, characterIndexForInsertion(at: point))
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Image files on the pasteboard, or pasted image data written to a temporary file.
    private func imageFiles(from board: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type) {
                let url = FileManager.default.temporaryDirectory.appending(path: "pasted-\(UUID().uuidString).\(type == .png ? "png" : "tiff")")
                if (try? data.write(to: url)) != nil { return [url] }
            }
        }
        return nil
    }
}

enum MarkdownStyler {
    /// Markers that stay visible everywhere: section breaks, code fences and anything inside code, math or front matter.
    static func keepVisible(_ range: NSRange, _ spans: [StyleSpan]) -> Bool {
        spans.contains { span in
            switch span.style {
            case .rule, .codeBlock, .math, .frontMatter: NSIntersectionRange(span.range, range).length > 0
            default: false
            }
        }
    }

    static let bodySize: CGFloat = 15
    static let sourceSize: CGFloat = 13

    static func paragraph(source: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = source ? 2 : 5
        p.paragraphSpacing = source ? 0 : 4
        return p
    }

    static func baseAttributes(source: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: source ? NSFont.monospacedSystemFont(ofSize: sourceSize, weight: .regular) : NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph(source: source),
        ]
    }

    /// Restyles the whole text and returns the Liquid ranges, which the view keeps whole.
    @discardableResult
    static func apply(to storage: NSTextStorage, source: Bool, activeRange: NSRange? = nil) -> [NSRange] {
        let full = NSRange(location: 0, length: storage.length)
        let spans = MarkdownScanner.scan(storage.string)
        var liquid: [NSRange] = []
        storage.beginEditing()
        storage.setAttributes(baseAttributes(source: source), range: full)
        let fm = NSFontManager.shared
        for span in spans where NSMaxRange(span.range) <= storage.length {
            let r = span.range
            switch span.style {
            case let .heading(level):
                if !source {
                    let sizes: [CGFloat] = [27, 22, 19, 17, 16, 15]
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[min(level, 6) - 1], weight: .bold), range: r)
                    let p = NSMutableParagraphStyle()
                    p.paragraphSpacingBefore = 8
                    p.paragraphSpacing = 4
                    storage.addAttribute(.paragraphStyle, value: p, range: r)
                } else {
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: sourceSize, weight: .bold), range: r)
                }
            case .bold:
                storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                    if let font = value as? NSFont { storage.addAttribute(.font, value: fm.convert(font, toHaveTrait: .boldFontMask), range: sub) }
                }
            case .italic:
                storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                    if let font = value as? NSFont { storage.addAttribute(.font, value: fm.convert(font, toHaveTrait: .italicFontMask), range: sub) }
                }
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: r)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular), range: r)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.5), range: r)
            case .codeBlock, .math:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize - 2, weight: .regular), range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                if !source {
                    let p = NSMutableParagraphStyle()
                    p.lineSpacing = 5
                    p.headIndent = 14
                    p.firstLineHeadIndent = 0
                    storage.addAttribute(.paragraphStyle, value: p, range: r)
                }
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
            case .link:
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r)
            case .url:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize - 3), range: r)
            case .image:
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: r)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize - 2, weight: .medium), range: r)
            case .footnoteRef:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
                storage.addAttribute(.baselineOffset, value: 5, range: r)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize - 4, weight: .semibold), range: r)
            case .footnoteDef:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize - 2), range: r)
            case .rule:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            case .liquid:
                liquid.append(r)
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: r)
                storage.addAttribute(.backgroundColor, value: NSColor.systemPurple.withAlphaComponent(0.12), range: r)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize - 3.5, weight: .medium), range: r)
            case .html:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            case .frontMatter:
                storage.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: r)
            case .syntax where activeRange.map { NSIntersectionRange($0, r).length == 0 && !keepVisible(r, spans) } == true:
                // Markers away from the cursor are kept in the text but drawn at almost no width.
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: r)
            case .syntax:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            }
        }
        storage.endEditing()
        return liquid
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var revision: Int
    var sourceMode: Bool
    var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InkwellTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Post text")
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.sourceMode = sourceMode
        textView.string = text
        textView.restyle()
        textView.onImportImages = { [weak model] urls, location in model?.importImages(urls, at: location) }
        textView.onLinkPicker = { [weak model] location in model?.linkPick = AppModel.LinkPick(location: location) }
        textView.onSlashAction = { [weak model] action, location in model?.slashAction(action, at: location) }
        textView.hidesSyntax = model.hideSyntax

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.revision = revision
        model.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? InkwellTextView else { return }
        context.coordinator.parent = self
        model.textView = textView
        let modeChanged = textView.sourceMode != sourceMode || textView.hidesSyntax != model.hideSyntax
        textView.hidesSyntax = model.hideSyntax
        if modeChanged || context.coordinator.revision != revision || (textView.string != text && !context.coordinator.isEditing) {
            context.coordinator.revision = revision
            textView.sourceMode = sourceMode
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            textView.restyle()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var revision = 0
        var isEditing = false

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            // While an input method is composing (accents, Chinese, Japanese), leave the text alone until it commits.
            guard let textView = notification.object as? InkwellTextView, !textView.hasMarkedText() else { return }
            isEditing = true
            textView.restyle()
            parent.text = textView.string
            isEditing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? InkwellTextView)?.selectionMoved()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let textView = notification.object as? InkwellTextView { parent.model.textView = textView }
        }
    }
}
