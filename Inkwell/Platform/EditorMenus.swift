import AppKit
import SwiftUI

/// View menu items for the editor: the formatting bar and text zoom. Zoom lasts for the session and leaves the text size
/// in Settings alone.
struct EditorViewCommands: View {
    var model: AppModel
    @AppStorage("ShowFormatBar") private var showFormatBar = true

    var body: some View {
        Toggle("Formatting Bar", isOn: $showFormatBar)
        Divider()
        Button("Zoom In") { model.textView?.zoom(step: 1) }
            .keyboardShortcut("+")
        Button("Zoom Out") { model.textView?.zoom(step: -1) }
            .keyboardShortcut("-")
        Button("Actual Size") { model.textView?.zoom(step: 0) }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}

/// Edit › Find, driving the post's find bar.
struct EditorFindCommands: View {
    var model: AppModel

    var body: some View {
        Menu("Find") {
            Button("Find…") { perform(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find and Replace…") { perform(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { perform(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { perform(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { perform(.setSearchString) }
            Button("Jump to Selection") { model.textView.map { $0.scrollRangeToVisible($0.selectedRange()) } }
                .keyboardShortcut("j")
        }
        .disabled(model.editor == nil)
    }

    /// The text finder reads the action from the sender's tag.
    func perform(_ action: NSTextFinder.Action) {
        guard let textView = model.textView else { return }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        if action == .showFindInterface || action == .showReplaceInterface { textView.window?.makeFirstResponder(textView) }
        textView.performTextFinderAction(sender)
    }
}
