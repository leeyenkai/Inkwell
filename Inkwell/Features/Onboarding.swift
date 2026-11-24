import InkwellKit
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var showToken = false

    var account: AccountModel { model.account }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Inkwell")
                .font(.largeTitle.weight(.semibold))
            Text("Write, design and publish your GitHub Pages site.\nSign in with GitHub to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            switch account.signIn {
            case let .enterCode(code):
                VStack(spacing: 10) {
                    Text("Enter this code on GitHub").font(.headline)
                    Text(code.user_code)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Code and Open GitHub") { account.copyCodeAndOpenGitHub(code) }
                        .buttonStyle(.borderedProminent)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for GitHub…").foregroundStyle(.secondary)
                    }
                    Button("Cancel") { account.cancelSignIn() }.buttonStyle(.link)
                }
            case .waitingForCode, .checking:
                ProgressView().controlSize(.small)
            default:
                if AccountModel.clientID != nil, !showToken {
                    Button("Sign in with GitHub") { account.startDeviceFlow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Use a personal access token instead") { showToken = true }.buttonStyle(.link)
                } else {
                    tokenForm
                }
            }
            if case let .failed(message) = account.signIn {
                Text(message).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            Divider().frame(width: 320).padding(.top, 6)
            Button("Open a site folder on this Mac (uses git)…") { model.openFolderPanel() }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(50)
        .frame(minWidth: 680, minHeight: 520)
    }

    var tokenForm: some View {
        VStack(spacing: 10) {
            Text("Create a token on GitHub with the **repo** and **workflow** scopes, then paste it here. It is kept in your keychain.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Link("Create a token on GitHub", destination: AccountModel.tokenURL)
            HStack {
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(signIn)
                Button("Sign In", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    func signIn() {
        let value = token
        token = ""
        Task {
            await account.useToken(value)
            if account.isSignedIn { model.showSitePicker = true }
        }
    }
}

struct SitePickerView: View {
    @Bindable var model: AppModel
    @State private var filter = ""
    @State private var showNewSite = false

    var account: AccountModel { model.account }

    var repos: [GitHubRepo] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return account.repositories.filter { query.isEmpty || $0.full_name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose your site").font(.title.weight(.semibold))
                    Text("Signed in as \(account.user?.login ?? "")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Site…") { showNewSite = true }
                    .buttonStyle(.borderedProminent)
            }
            TextField("Search repositories", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(repos) { repo in
                HStack(spacing: 12) {
                    Image(systemName: repo.isUserSite ? "globe" : repo.has_pages == true ? "doc.richtext" : "folder")
                        .foregroundStyle(repo.has_pages == true || repo.isUserSite ? Color.accentColor : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.full_name).font(.headline)
                        Text(repo.has_pages == true
                            ? String(localized: "GitHub Pages site") : (repo.description ?? String(localized: "Repository")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if repo.private { Image(systemName: "lock").foregroundStyle(.secondary).help("Private repository") }
                    Button("Open") { Task { await model.open(repository: repo) } }
                        .disabled(model.opening != nil || !repo.canPush)
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if account.loadingRepositories {
                    ProgressView()
                } else if let error = account.repositoryError {
                    ContentUnavailableView("Could not load repositories", systemImage: "wifi.exclamationmark", description: Text(error))
                }
            }
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Sign Out") { account.signOut() }
                Button("Open a Folder…") { model.openFolderPanel() }
                Spacer()
                if model.site != nil {
                    Button("Cancel") { model.showSitePicker = false }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 520)
        .task { if account.repositories.isEmpty { await account.loadRepositories() } }
        .sheet(isPresented: $showNewSite) { NewSiteSheet(model: model) }
        .overlay {
            if let opening = model.opening { OpeningOverlay(message: opening) }
        }
    }
}

struct OpeningOverlay: View {
    var message: String

    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.75))
            VStack(spacing: 12) {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
            .padding(30)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct NewSiteSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var userSite = true
    @State private var projectName = "my-site"
    @State private var themeID = "essayist"
    let themes = ThemeManifest.bundled()

    var login: String { model.account.user?.login ?? "you" }
    var userSiteTaken: Bool { model.account.repositories.contains { $0.name.lowercased() == "\(login.lowercased()).github.io" } }
    var repoName: String { userSite && !userSiteTaken ? "\(login).github.io" : Slug.make(projectName) }
    var address: String { userSite && !userSiteTaken ? "\(login).github.io" : "\(login).github.io/\(repoName)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New site").font(.title2.weight(.semibold))
            Form {
                TextField("Site title", text: $title, prompt: Text("My notebook"))
                Picker("Address", selection: $userSite) {
                    Text(userSiteTaken ? String(localized: "\(login).github.io (already used)") : "\(login).github.io").tag(true)
                    Text(verbatim: "\(login).github.io/…").tag(false)
                }
                .disabled(userSiteTaken)
                if !userSite || userSiteTaken {
                    TextField("Name", text: $projectName)
                }
                LabeledContent("It will be at") { Text(address).font(.callout.monospaced()) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Theme").font(.headline)
            HStack(spacing: 12) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, selected: theme.id == themeID)
                        .choosable(theme.name, selected: theme.id == themeID) { themeID = theme.id }
                }
            }
            HStack {
                Text("Creates a public repository, turns on GitHub Pages and publishes a first post you can edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Site") {
                    let theme = themes.first { $0.id == themeID } ?? themes[0]
                    let name = repoName, siteTitle = title.isEmpty ? "My site" : title
                    dismiss()
                    Task { await model.createSite(name: name, title: siteTitle, theme: theme) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(repoName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720)
        .onAppear { if userSiteTaken { userSite = false } }
    }
}

struct ThemeCard: View {
    var theme: ThemeManifest
    var selected: Bool

    func color(_ name: String, dark: Bool = false) -> Color {
        let token = theme.tokens.first { $0.name == name }
        return Color(hex: (dark ? token?.dark : token?.light) ?? "#888888")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                miniPage(dark: false)
                miniPage(dark: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(theme.name).font(.headline)
            Text(theme.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(height: 44, alignment: .top)
        }
        .padding(10)
        .frame(width: 158)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    func miniPage(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color("--text", dark: dark)).frame(width: 40, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(color("--accent", dark: dark)).frame(width: 52, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(color("--muted", dark: dark)).frame(width: 60, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(color("--muted", dark: dark)).frame(width: 48, height: 3)
        }
        .padding(8)
        .frame(width: 69, height: 64, alignment: .topLeading)
        .background(color("--bg", dark: dark))
    }
}

extension Color {
    init(hex: String) {
        var digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if digits.count == 3 || digits.count == 4 { digits = String(digits.prefix(3).flatMap { [$0, $0] }) }
        var value: UInt64 = 0
        Scanner(string: String(digits.prefix(6))).scanHexInt64(&value)
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
