import AppKit
import InkwellKit
import SwiftUI

/// What the link popover shows and does. The text view creates one per popover and handles the choices.
@Observable
final class LinkPopoverModel {
    enum Mode: Equatable {
        case search
        /// The cursor is in a link: show where it goes, with Open, Edit and Remove Link.
        case existing
    }

    var mode: Mode
    var query = "" {
        didSet {
            if query != oldValue { refresh() }
        }
    }

    var highlighted = 0
    private(set) var results: [LinkSuggestion] = []
    let link: MarkdownLink?
    /// The post or page an existing link leads to, when it is one of this site's.
    let linkedTitle: String?
    private let entries: [LinkSearch.Entry]
    private let headings: [HeadingAnchor]
    private let context: String
    private let clipboard: String?
    var onChoose: (LinkSuggestion) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}
    var onClose: () -> Void = {}

    init(link: MarkdownLink?, entries: [LinkSearch.Entry], headings: [HeadingAnchor], context: String, clipboard: String?) {
        self.link = link
        self.entries = entries
        self.headings = headings
        self.context = context
        self.clipboard = clipboard
        mode = link == nil ? .search : .existing
        linkedTitle = link.flatMap { link in
            if link.url.hasPrefix("#") { return headings.first { "#" + $0.anchor == link.url }?.title }
            return entries.first { $0.url == link.url }?.title
        }
        refresh()
    }

    func refresh() {
        results = LinkSearch.results(query: query, context: context, clipboard: mode == .search && link == nil ? clipboard : nil,
                                     entries: entries, headings: headings)
        highlighted = 0
    }

    func edit() {
        query = link?.url ?? ""
        mode = .search
        refresh()
    }

    func move(_ by: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(0, highlighted + by), results.count - 1)
    }

    func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        onChoose(results[highlighted])
    }
}

struct LinkPopoverView: View {
    @Bindable var model: LinkPopoverModel

    var body: some View {
        Group {
            switch model.mode {
            case .existing: existing
            case .search: search
            }
        }
        .frame(width: 380)
        .onExitCommand { model.onClose() }
    }

    var existing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: model.link?.url ?? ""))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    if let title = model.linkedTitle {
                        Text(title).font(.body.weight(.medium)).lineLimit(2)
                    }
                    Text(model.link?.url ?? "")
                        .font(model.linkedTitle == nil ? .body : .caption)
                        .foregroundStyle(model.linkedTitle == nil ? .primary : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Link to \(model.linkedTitle ?? model.link?.url ?? "")"))
            HStack(spacing: 8) {
                Button("Remove Link") { model.onRemove() }
                    .help("Remove the link and keep its text")
                Spacer()
                Button("Open") { model.onOpen() }
                    .help("Open the linked page")
                Button("Edit") { model.edit() }
                    .keyboardShortcut(.defaultAction)
                    .help("Change where the link goes")
            }
            .controlSize(.regular)
        }
        .padding(14)
    }

    var search: some View {
        VStack(spacing: 0) {
            LinkSearchField(model: model)
                .frame(height: 24)
                .padding(10)
            Divider()
            if model.results.isEmpty {
                Text(model.query.isEmpty ? "Type to find a post, or paste a link." : "No posts or pages match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                row(result, highlighted: index == model.highlighted)
                                    .id(index)
                                    .onTapGesture { model.onChoose(result) }
                                    .onHover { if $0 { model.highlighted = index } }
                            }
                        }
                        .padding(5)
                    }
                    .frame(height: min(CGFloat(model.results.count) * 40 + 10, 290))
                    .onChange(of: model.highlighted) { proxy.scrollTo(model.highlighted) }
                }
            }
            Divider()
            HStack {
                Text("Return to link, Esc to close")
                Spacer()
                if model.link != nil {
                    Button("Remove Link") { model.onRemove() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    func row(_ result: LinkSuggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol(result))
                .foregroundStyle(highlighted ? Color.white : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !result.detail.isEmpty {
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? Color.white : .primary)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    func symbol(_ result: LinkSuggestion) -> String {
        switch result.kind {
        case .web: "globe"
        case .email: "envelope"
        case .post: "doc.text"
        case .heading: "number"
        }
    }

    func symbol(for url: String) -> String {
        if url.hasPrefix("mailto:") { return "envelope" }
        if url.hasPrefix("#") { return "number" }
        if url.hasPrefix("/") { return "doc.text" }
        return "globe"
    }
}

/// A search field that passes the arrow keys, Return and Escape to the popover, so it works from the keyboard alone.
struct LinkSearchField: NSViewRepresentable {
    var model: LinkPopoverModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.placeholderString = String(localized: "Search posts, or paste a link")
        field.setAccessibilityLabel(String(localized: "Link to"))
        field.delegate = context.coordinator
        field.stringValue = model.query
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        return field
    }

    func updateNSView(_ field: FocusingSearchField, context: Context) {
        context.coordinator.model = model
        if field.stringValue != model.query, field.currentEditor() == nil { field.stringValue = model.query }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var model: LinkPopoverModel

        init(model: LinkPopoverModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.move(1)
            case #selector(NSResponder.moveUp(_:)):
                model.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                model.chooseHighlighted()
            case #selector(NSResponder.cancelOperation(_:)):
                model.onClose()
            default:
                return false
            }
            return true
        }
    }
}

/// Takes the keyboard as soon as the popover shows.
final class FocusingSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}
