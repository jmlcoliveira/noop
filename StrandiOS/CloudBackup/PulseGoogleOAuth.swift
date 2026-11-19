import Foundation

struct PulseGoogleOAuth: Sendable {
    static let provider = "google.com"
    static let callbackScheme = "pulseauth"
    static let redirectURI = "https://pulse.joliveira.xyz/auth/google/callback"

    let authorizationURL: URL
    let sessionID: String
    private let state: String

    init?(authorizationURL: URL, sessionID: String) {
        guard !sessionID.isEmpty,
              let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "accounts.google.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.fragment == nil,
              Self.value("response_type", in: components) == "code",
              Self.value("redirect_uri", in: components) == Self.redirectURI,
              let state = Self.value("state", in: components) else { return nil }
        self.authorizationURL = authorizationURL
        self.sessionID = sessionID
        self.state = state
    }

    enum Callback: Equatable {
        case authorized(URL)
        case cancelled
        case invalid
    }

    func callback(_ url: URL) -> Callback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.callbackScheme, components.host == "google",
              components.percentEncodedPath == "/callback",
              components.port == nil, components.user == nil, components.password == nil,
              components.fragment == nil,
              Self.value("state", in: components) == state else { return .invalid }
        let items = components.queryItems ?? []
        if Self.value("error", in: components) == "access_denied", !items.contains(where: { $0.name == "code" }) {
            return .cancelled
        }
        guard !items.contains(where: { $0.name == "error" }),
              Self.value("code", in: components) != nil,
              let query = components.percentEncodedQuery,
              let requestURI = URL(string: "\(Self.redirectURI)?\(query)") else { return .invalid }
        return .authorized(requestURI)
    }

    private static func value(_ name: String, in components: URLComponents) -> String? {
        let matches = components.queryItems?.filter { $0.name == name } ?? []
        guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
        return value
    }
}
