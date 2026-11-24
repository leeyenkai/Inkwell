import InkwellKit
import SwiftUI

struct SettingsWindow: View {
    var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Editor", systemImage: "character.cursor.ibeam") { EditorSettings(model: model) }
            Tab("Images", systemImage: "photo") { ImageSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings(model: model) }
        }
        .frame(width: 500, height: 340)
    }
}

struct GeneralSettings: View {
    var model: AppModel
    @AppStorage(Prefs.reopenLastSite) private var reopen = true
    @AppStorage(Prefs.syncMinutes) private var minutes = 5

    var body: some View {
        Form {
            Toggle("Open the last site when Inkwell starts", isOn: $reopen)
            Picker("Check GitHub for changes", selection: $minutes) {
                Text("Every 2 minutes").tag(2)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every hour").tag(60)
            }
            .onChange(of: minutes) { model.restartSyncLoop() }
            Text("Inkwell also checks when you come back to it, and before every publish.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct EditorSettings: View {
    var model: AppModel
    @AppStorage(Prefs.editorFontSize) private var size = 15.0
    @AppStorage(Prefs.inlineImages) private var images = true
    @AppStorage(Prefs.spellCheck) private var spelling = true
    @AppStorage(Prefs.smartQuotes) private var quotes = false

    var body: some View {
        Form {
            LabeledContent("Text size") {
                HStack {
                    Slider(value: $size, in: 12 ... 22, step: 1).frame(width: 180)
                    Text("\(String(Int(size))) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Toggle("Hide Markdown syntax away from the cursor", isOn: Binding(get: { model.hideSyntax }, set: { model.hideSyntax = $0 }))
            Toggle("Show pictures in the text", isOn: $images)
            Toggle("Check spelling while typing", isOn: $spelling)
            Toggle("Use smart quotes and dashes", isOn: $quotes)
            Text("Smart quotes change what you type into curly quotes and dashes, which Markdown keeps as they are.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: size) { model.editorPreferencesChanged() }
        .onChange(of: images) { model.editorPreferencesChanged() }
        .onChange(of: spelling) { model.editorPreferencesChanged() }
        .onChange(of: quotes) { model.editorPreferencesChanged() }
    }
}

struct ImageSettings: View {
    @AppStorage(Prefs.imageMaxSize) private var maxSize = 2400
    @AppStorage(Prefs.jpegQuality) private var quality = 0.82

    var body: some View {
        Form {
            Picker("Longest side", selection: $maxSize) {
                Text("1600 pixels").tag(1600)
                Text("2400 pixels").tag(2400)
                Text("3200 pixels").tag(3200)
            }
            LabeledContent("JPEG quality") {
                HStack {
                    Slider(value: $quality, in: 0.6 ... 0.95, step: 0.01).frame(width: 180)
                    Text(quality, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Text("""
                Pictures are turned upright and lose their location and camera data whatever these are set to. \
                Settings apply to pictures added from now on.
                """)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}

struct AccountSettings: View {
    var model: AppModel

    var body: some View {
        Form {
            if let user = model.account.user {
                LabeledContent("Signed in as") { Text(user.name.map { "\($0) (\(user.login))" } ?? user.login) }
                Text("The sign-in is kept in your keychain and used only to talk to GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sign Out of GitHub") { model.signOut() }
            } else {
                Text("Not signed in. Open a site to sign in with GitHub.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
