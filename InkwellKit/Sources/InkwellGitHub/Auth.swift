import Foundation
import Security

/// Sign in with GitHub's device flow: the app shows a short code, the person enters it at github.com/login/device,
/// and the app receives a token. Needs only the OAuth App's client ID, never a secret.
public struct DeviceFlow: Sendable {
    public var clientID: String
    public var scopes: [String]
    var loginURL: URL
    var session: URLSession

    public init(clientID: String, scopes: [String] = ["public_repo", "workflow"], loginURL: URL = URL(string: "https://github.com/login")!,
                session: URLSession = .shared) {
        self.clientID = clientID
        self.scopes = scopes
        self.loginURL = loginURL
        self.session = session
    }

    public struct Code: Decodable, Sendable, Equatable {
        public var device_code: String
        public var user_code: String
        public var verification_uri: String
        public var expires_in: Int
        public var interval: Int
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case expired
        case denied
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .expired: localized("The code expired. Start again.")
            case .denied: localized("Access was declined on GitHub.")
            case let .other(message): message
            }
        }
    }

    public func start() async throws -> Code {
        let (data, _) = try await post("device/code", ["client_id": clientID, "scope": scopes.joined(separator: " ")])
        if let code = try? JSONDecoder().decode(Code.self, from: data) { return code }
        throw Failure.other(Self.message(data) ?? localized("GitHub did not start the sign-in."))
    }

    /// Waits until the person approves (or declines) on GitHub, following GitHub's polling interval.
    public func waitForToken(_ code: Code, minimumInterval: Int = 5) async throws -> String {
        var interval = max(code.interval, minimumInterval)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (data, _) = try await post("oauth/access_token", [
                "client_id": clientID, "device_code": code.device_code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let reply = (try? JSONDecoder().decode(TokenReply.self, from: data)) ?? TokenReply()
            if let token = reply.access_token { return token }
            switch reply.error {
            case "authorization_pending": continue
            case "slow_down": interval += max(minimumInterval, 1)
            case "expired_token": throw Failure.expired
            case "access_denied": throw Failure.denied
            default: throw Failure.other(reply.error_description ?? reply.error ?? localized("Sign-in failed."))
            }
        }
        throw Failure.expired
    }

    struct TokenReply: Decodable {
        var access_token: String?
        var error: String?
        var error_description: String?
    }

    func post(_ path: String, _ form: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: loginURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        do {
            return try await session.data(for: request)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
    }

    static func message(_ data: Data) -> String? {
        (try? JSONDecoder().decode(TokenReply.self, from: data)).flatMap { $0.error_description ?? $0.error }
    }
}

/// The GitHub token, kept in the login keychain and nowhere else.
public struct TokenStore: Sendable {
    public var service: String

    public init(service: String = "com.yenkai.Inkwell.github") {
        self.service = service
    }

    public func save(_ token: String, account: String) throws {
        delete()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: Data(token.utf8), kSecAttrLabel: "Inkwell GitHub sign-in",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubError.http(status: Int(status), message: localized("Could not save the sign-in to the keychain.")) }
    }

    public func load() -> (account: String, token: String)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true, kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let item = result as? [CFString: Any],
              let data = item[kSecValueData] as? Data, let account = item[kSecAttrAccount] as? String else { return nil }
        return (account, String(decoding: data, as: UTF8.self))
    }

    public func delete() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
