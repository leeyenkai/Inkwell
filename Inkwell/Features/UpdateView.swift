import InkwellKit
import SwiftUI

/// The Software Update window: the result of a check, and the new version's notes when there is one.
struct UpdateView: View {
    var updates: Updates
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var content: some View {
        switch updates.state {
        case .idle, .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("Inkwell is up to date").font(.headline)
            Text("Version \(updates.currentVersion) is the newest.").foregroundStyle(.secondary)
            closeButton
        case .unavailable:
            Text("No updates to show").font(.headline)
            Text("Inkwell could not find a published version to compare with.").foregroundStyle(.secondary)
            closeButton
        case let .failed(message):
            Text("Could not check for updates").font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            closeButton
        case let .available(release):
            Text("Inkwell \(release.version) is available").font(.headline)
            Text("You have \(updates.currentVersion). Download the new version, quit Inkwell, then drag the new one into Applications.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(notes(release.notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
            Text("Your drafts, sites and sign-in stay as they are.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Skip This Version") {
                    updates.skip(release)
                    dismissWindow(id: "update")
                }
                Spacer()
                Button("Not Now") { dismissWindow(id: "update") }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    updates.download(release)
                    dismissWindow(id: "update")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    var closeButton: some View {
        HStack {
            Spacer()
            Button("OK") { dismissWindow(id: "update") }.keyboardShortcut(.defaultAction)
        }
    }

    /// Release notes are Markdown; headings and lists keep their line breaks.
    func notes(_ text: String) -> AttributedString {
        let text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("- ") || line.hasPrefix("* ") ? "•  " + line.dropFirst(2) : String(line)
        }
        .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// "Check for Updates…" in the app menu: a view, so it can open the window.
struct CheckForUpdatesItem: View {
    var updates: Updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            openWindow(id: "update")
            Task { await updates.check(userInitiated: true) }
        }
    }
}
