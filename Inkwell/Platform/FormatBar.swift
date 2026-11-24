import AppKit
import InkwellKit
import SwiftUI

/// The formatting at the cursor and the size of the selection, kept up to date by the text view for the formatting bar
/// and the word count.
@Observable
final class EditorFormatState {
    var state = FormatState()
    var selectedWords = 0
    var selectedCharacters = 0
}

/// Paragraph styles offered in the formatting bar, as Markdown: `#`, `##`, `###`, plain, or a fenced code block.
enum TextStyle: CaseIterable, Identifiable {
    case title, heading, subheading, body, monospaced

    var id: Self { self }

    var name: String {
        switch self {
        case .title: String(localized: "Title")
        case .heading: String(localized: "Heading")
        case .subheading: String(localized: "Subheading")
        case .body: String(localized: "Body")
        case .monospaced: String(localized: "Monospaced")
        }
    }

    init(_ block: FormatState.Block) {
        switch block {
        case .heading(1): self = .title
        case .heading(2): self = .heading
        case .heading: self = .subheading
        case .code: self = .monospaced
        case .body: self = .body
        }
    }
}

/// A compact bar of formatting controls above the text. Every control goes through the text view's commands, so each
/// is one undo step and the Markdown stays as typed.
struct FormatBar: View {
    var model: AppModel
    var format: EditorFormatState

    var body: some View {
        let state = format.state
        HStack(spacing: 2) {
            styleMenu(state)
            separator
            toggle("bold", String(localized: "Bold"), "⌘B", state.bold) { $0.toggle("**") }
            toggle("italic", String(localized: "Italic"), "⌘I", state.italic) { $0.toggle("*") }
            toggle("underline", String(localized: "Underline"), "⌘U", state.underline) { $0.toggle("<u>", "</u>") }
            toggle("strikethrough", String(localized: "Strikethrough"), "⇧⌘X", state.strikethrough) { $0.toggle("~~") }
            toggle("highlighter", String(localized: "Highlight"), "⇧⌘H", state.highlight) { $0.toggle("<mark>", "</mark>") }
            separator
            toggle("link", String(localized: "Link"), "⌘K", state.link) { $0.showLinkPopover() }
            separator
            toggle("list.bullet", String(localized: "Bulleted List"), "⇧⌘L", state.list == .bullets) { $0.setList(.bullets) }
            toggle("list.number", String(localized: "Numbered List"), nil, state.list == .numbers) { $0.setList(.numbers) }
            toggle("checklist", String(localized: "Checklist"), "⌥⌘L", state.list == .checklist) { $0.setList(.checklist) }
            separator
            toggle("text.quote", String(localized: "Quote"), "⌘'", state.quote) { $0.prefixLines("> ") }
            toggle("chevron.left.forwardslash.chevron.right", String(localized: "Inline Code"), "⌘E", state.code) { $0.toggle("`") }
            toggle("tablecells", String(localized: "Table"), "⇧⌘T", false) { $0.editTable() }
            toggle("photo", String(localized: "Image"), "⇧⌘I", false) { textView in
                model.slashAction("image", at: textView.selectedRange().location)
            }
            if let language = state.codeLanguage {
                separator
                languageMenu(language)
            }
            Spacer(minLength: 8)
            insertButton
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: InkwellTextView.columnWidth + 56)
        .frame(maxWidth: .infinity)
        .disabled(model.textView == nil)
    }

    var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 5)
    }

    func run(_ action: (InkwellTextView) -> Void) {
        guard let textView = model.textView else { return }
        textView.window?.makeFirstResponder(textView)
        action(textView)
    }

    func toggle(_ symbol: String, _ name: String, _ shortcut: String?, _ active: Bool,
                action: @escaping (InkwellTextView) -> Void) -> some View {
        Button {
            run(action)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(FormatButtonStyle(active: active))
        .help(shortcut.map { "\(name) (\($0))" } ?? name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    func styleMenu(_ state: FormatState) -> some View {
        let current = TextStyle(state.block)
        return Menu {
            ForEach(TextStyle.allCases) { style in
                Toggle(isOn: Binding(get: { current == style }, set: { _ in run { $0.setTextStyle(style) } })) {
                    Text(style.name)
                }
            }
        } label: {
            Text(current.name).frame(width: 84, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Paragraph style")
        .accessibilityLabel("Paragraph style")
        .accessibilityValue(current.name)
    }

    func languageMenu(_ language: String) -> some View {
        Menu {
            Button("None") { run { $0.setCodeLanguage("") } }
            Divider()
            ForEach(EditorCommands.codeLanguages, id: \.self) { name in
                Button(name) { run { $0.setCodeLanguage(name) } }
            }
        } label: {
            Text(language.isEmpty ? String(localized: "Language") : language)
                .font(.callout.monospaced())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The code block’s language, used for colouring it on the site")
        .accessibilityLabel("Code language")
    }

    var insertButton: some View {
        Button {
            run { $0.insertElement() }
        } label: {
            Label("Insert", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(FormatButtonStyle(active: false, wide: true))
        .help("Insert an element")
        .accessibilityLabel("Insert")
    }
}

/// Plain icon buttons that show a soft background on hover and a tinted one when the style is on.
struct FormatButtonStyle: ButtonStyle {
    var active: Bool
    var wide = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(minWidth: wide ? nil : 26, minHeight: 24)
            .padding(.horizontal, wide ? 8 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.16)
                        : configuration.isPressed ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
