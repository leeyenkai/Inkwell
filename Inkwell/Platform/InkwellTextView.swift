import AppKit
import InkwellKit
import SwiftUI
import UniformTypeIdentifiers

/// The writing surface: a plain-text view over the Markdown source, styled live. Styling is attributes only,
/// so the file always holds exactly what was typed.
final class InkwellTextView: NSTextView {
    var onImportImages: (([URL], Int) -> Void)?
    var sourceMode = false
    private(set) var liquidRanges: [NSRange] = []
    static let columnWidth: CGFloat = 700

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, (newSize.width - Self.columnWidth) / 2)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: 8) }
    }

    func restyle() {
        guard let storage = textStorage else { return }
        liquidRanges = MarkdownStyler.apply(to: storage, source: sourceMode)
        typingAttributes = MarkdownStyler.baseAttributes(source: sourceMode)
    }

    // Liquid tags behave as one piece: they can be selected and deleted whole, but not edited from inside.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !sourceMode {
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
    static func apply(to storage: NSTextStorage, source: Bool) -> [NSRange] {
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
        let modeChanged = textView.sourceMode != sourceMode
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
            guard let textView = notification.object as? InkwellTextView else { return }
            isEditing = true
            textView.restyle()
            parent.text = textView.string
            isEditing = false
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let textView = notification.object as? InkwellTextView { parent.model.textView = textView }
        }
    }
}
