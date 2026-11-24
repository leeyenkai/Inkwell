import AppKit
import InkwellKit
import Observation

/// The signed-in GitHub account. The token lives in the keychain only.
@Observable
final class AccountModel {
    enum SignIn: Equatable {
        case idle
        case waitingForCode
        case enterCode(DeviceFlow.Code)
        case checking
        case failed(String)
    }

    private(set) var user: GitHubUser?
    private(set) var client: GitHubClient?
    var signIn: SignIn = .idle
    private(set) var repositories: [GitHubRepo] = []
    private(set) var loadingRepositories = false
    var repositoryError: String?
    private var flowTask: Task<Void, Never>?
    private let store = TokenStore()

    /// The OAuth App's client ID, set in Info.plist. Without it, sign-in uses a personal access token.
    static var clientID: String? {
        let id = Bundle.main.object(forInfoDictionaryKey: "InkwellGitHubClientID") as? String
        return id?.isEmpty == false ? id : nil
    }

    static let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=Inkwell")!

    var isSignedIn: Bool { user != nil }

    func restore() async {
        guard user == nil, let saved = store.load() else { return }
        let client = GitHubClient(token: saved.token)
        do {
            user = try await client.user()
            self.client = client
        } catch GitHubError.unauthorized {
            store.delete()
        } catch {
            // Offline: keep the saved sign-in and work with what is on this Mac.
            user = GitHubUser(login: saved.account, name: nil, avatar_url: nil)
            self.client = client
        }
    }

    func startDeviceFlow() {
        guard let clientID = Self.clientID else { return }
        flowTask?.cancel()
        signIn = .waitingForCode
        flowTask = Task {
            let flow = DeviceFlow(clientID: clientID)
            do {
                let code = try await flow.start()
                signIn = .enterCode(code)
                let token = try await flow.waitForToken(code)
                await useToken(token)
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed(error.localizedDescription)
            }
        }
    }

    func copyCodeAndOpenGitHub(_ code: DeviceFlow.Code) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.user_code, forType: .string)
        if let url = URL(string: code.verification_uri) { NSWorkspace.shared.open(url) }
    }

    func useToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        signIn = .checking
        let client = GitHubClient(token: trimmed)
        do {
            let user = try await client.user()
            try store.save(trimmed, account: user.login)
            self.user = user
            self.client = client
            signIn = .idle
            await loadRepositories()
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    func cancelSignIn() {
        flowTask?.cancel()
        signIn = .idle
    }

    func signOut() {
        store.delete()
        user = nil
        client = nil
        repositories = []
    }

    func loadRepositories() async {
        guard let client else { return }
        loadingRepositories = true
        repositoryError = nil
        do {
            let repos = try await client.repositories()
            let login = user?.login.lowercased() ?? ""
            repositories = repos.sorted { a, b in
                func rank(_ r: GitHubRepo) -> Int {
                    if r.isUserSite, r.owner.login.lowercased() == login { return 0 }
                    if r.has_pages == true { return 1 }
                    return 2
                }
                return (rank(a), b.pushed_at ?? "") < (rank(b), a.pushed_at ?? "")
            }
        } catch {
            repositoryError = error.localizedDescription
        }
        loadingRepositories = false
    }
}
