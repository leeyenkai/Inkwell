import AppKit
import SwiftUI

/// Colours for layouts, styles and config: HTML tags, Liquid, CSS properties and Sass variables, YAML keys, comments.
enum CodeHighlighter {
    struct Rule {
        var pattern: NSRegularExpression
        var color: NSColor
        var group = 0
    }

    static func rules(for ext: String) -> [Rule] {
        func r(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) -> Rule? {
            (try? NSRegularExpression(pattern: pattern, options: options)).map { Rule(pattern: $0, color: color, group: group) }
        }
        let liquid = [r(#"\{\{.*?\}\}|\{%.*?%\}"#, .systemPurple, options: [.dotMatchesLineSeparators])]
        switch ext {
        case "html", "htm", "xml", "md", "markdown":
            return ([r(#"</?[A-Za-z][A-Za-z0-9-]*"#, .systemBlue), r(#"/?>"#, .systemBlue), r(#"\s([a-zA-Z:-]+)="#, .systemTeal, group: 1),
                     r(#""[^"\n]*""#, .systemOrange)] + liquid + [r(#"<!--.*?-->"#, .secondaryLabelColor, options: [.dotMatchesLineSeparators])])
                .compactMap { $0 }
        case "css", "scss", "sass":
            return ([r(#"([a-zA-Z-]+)\s*:(?!:)"#, .systemTeal, group: 1), r(#"#[0-9a-fA-F]{3,8}\b"#, .systemOrange), r(#"\$[A-Za-z0-9_-]+"#, .systemPurple),
                     r(#"@[a-z-]+"#, .systemPink), r(#""[^"\n]*"|'[^'\n]*'"#, .systemOrange)] + liquid
                + [r(#"/\*.*?\*/"#, .secondaryLabelColor, options: [.dotMatchesLineSeparators]), r(#"(?m)//.*$"#, .secondaryLabelColor)])
                .compactMap { $0 }
        case "yml", "yaml", "json":
            return [r(#"(?m)^\s*-?\s*([A-Za-z0-9_-]+):"#, .systemBlue, group: 1), r(#""[^"\n]*"|'[^'\n]*'"#, .systemOrange),
                    r(#"(?m)#.*$"#, .secondaryLabelColor)].compactMap { $0 }
        case "js":
            return [r(#"\b(const|let|var|function|return|if|else|for|while|import|export|new|class)\b"#, .systemPink),
                    r(#""[^"\n]*"|'[^'\n]*'|`[^`]*`"#, .systemOrange), r(#"(?m)//.*$"#, .secondaryLabelColor)].compactMap { $0 }
        default:
            return liquid.compactMap { $0 }
        }
    }

    static func apply(to storage: NSTextStorage, ext: String) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor.textColor], range: full)
        for rule in rules(for: ext) {
            for m in rule.pattern.matches(in: storage.string, range: full) {
                let range = m.range(at: rule.group)
                if range.location != NSNotFound { storage.addAttribute(.foregroundColor, value: rule.color, range: range) }
            }
        }
        storage.endEditing()
    }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fileExtension: String
    var editable: Bool
    /// Changes when another file is shown, so the text is replaced rather than edited.
    var identity: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(String(localized: "Code"))
        load(textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if context.coordinator.identity != identity || (textView.string != text && !context.coordinator.isEditing) {
            load(textView, coordinator: context.coordinator)
        }
        textView.isEditable = editable
    }

    func load(_ textView: NSTextView, coordinator: Coordinator) {
        coordinator.identity = identity
        textView.string = text
        textView.isEditable = editable
        if let storage = textView.textStorage { CodeHighlighter.apply(to: storage, ext: fileExtension) }
        textView.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var identity = ""
        var isEditing = false

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            isEditing = true
            if let storage = textView.textStorage { CodeHighlighter.apply(to: storage, ext: parent.fileExtension) }
            parent.text = textView.string
            isEditing = false
        }
    }
}
