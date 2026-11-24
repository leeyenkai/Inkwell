import AppKit
import InkwellKit

/// Page elements in the editor: their wrapper lines step back as small grey text, and the element under the cursor
/// gets an Edit button for its settings. The text itself is never changed by this.
extension InkwellTextView {
    func styleElements(in storage: NSTextStorage) {
        let text = storage.string
        // Cheap check first: most posts have no elements.
        guard !sourceMode, text.contains("markdown=") || text.contains("ik-button") || text.contains("include inkwell/") else {
            elementSpans = []
            return
        }
        elementSpans = PageElements.find(in: text)
        let font = NSFont.monospacedSystemFont(ofSize: max(10, MarkdownStyler.bodySize - 4), weight: .regular)
        storage.beginEditing()
        for span in elementSpans {
            for range in [span.openRange, span.closeRange].compactMap({ $0 }) where NSMaxRange(range) <= storage.length {
                // Buttons and includes are the element itself: keep them readable, just quieter.
                let wrapper = span.closeRange != nil
                storage.addAttribute(.font, value: font, range: range)
                storage.addAttribute(.foregroundColor, value: wrapper ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor, range: range)
            }
        }
        // Wrapper lines inside elements (a column's <div markdown="1">, closing tags) step back too.
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let isWrapper = (content.hasPrefix("<") && content.hasSuffix(">") && content.contains("markdown=\"1\""))
                || ["</div>", "</details>", "</section>"].contains(content)
            guard isWrapper else { continue }
            let range = NSRange(location: line.location, length: line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
        storage.endEditing()
    }

    /// The innermost element at the cursor.
    var elementAtCursor: ElementSpan? {
        let location = selectedRange().location
        return elementSpans.filter { location >= $0.range.location && location <= NSMaxRange($0.range) }.min { $0.range.length < $1.range.length }
    }

    func updateElementButton() {
        guard !sourceMode, let span = elementAtCursor, NSMaxRange(span.openRange) <= (string as NSString).length, let layout = layoutManager else {
            elementButton.isHidden = true
            return
        }
        elementButton.title = String(localized: "Edit \(span.kind.title)…")
        elementButton.setAccessibilityHelp(String(localized: "Change this element’s settings"))
        elementButton.sizeToFit()
        let glyph = layout.glyphIndexForCharacter(at: span.openRange.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = textContainerOrigin.x + (textContainer?.size.width ?? contentWidth) - elementButton.frame.width
        elementButton.setFrameOrigin(NSPoint(x: x, y: textContainerOrigin.y + line.minY + (line.height - elementButton.frame.height) / 2))
        elementButton.isHidden = false
    }

    @objc func editElementFromButton() {
        guard let span = elementAtCursor else { return }
        onEditElement?(span.openRange.location)
    }
}
