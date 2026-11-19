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

    enum CallbackFailure: String, Sendable {
        case endpointMismatch
        case stateMissing
        case stateMismatch
        case providerError
        case codeMissing
        case ambiguousParameters
    }

    enum CheckedCallback: Equatable, Sendable {
        case authorized(URL)
        case cancelled
        case rejected(CallbackFailure)
    }

    func callback(_ url: URL) -> Callback {
        switch checkedCallback(url) {
        case .authorized(let requestURI): .authorized(requestURI)
        case .cancelled: .cancelled
        case .rejected: .invalid
        }
    }

    func checkedCallback(_ url: URL) -> CheckedCallback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.callbackScheme, components.host == "google",
              components.percentEncodedPath == "/callback",
              components.port == nil, components.user == nil, components.password == nil,
              components.percentEncodedFragment?.isEmpty != false else { return .rejected(.endpointMismatch) }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        guard states.count <= 1, codes.count <= 1, errors.count <= 1, codes.isEmpty || errors.isEmpty else {
            return .rejected(.ambiguousParameters)
        }
        guard let receivedState = states.first?.value, !receivedState.isEmpty else { return .rejected(.stateMissing) }
        guard receivedState == state else { return .rejected(.stateMismatch) }
        if let error = errors.first {
            return error.value == "access_denied" ? .cancelled : .rejected(.providerError)
        }
        guard let code = codes.first?.value, !code.isEmpty else { return .rejected(.codeMissing) }
        guard let query = components.percentEncodedQuery,
              let requestURI = URL(string: "\(Self.redirectURI)?\(query)") else {
            return .rejected(.endpointMismatch)
        }
        return .authorized(requestURI)
    }

    private static func value(_ name: String, in components: URLComponents) -> String? {
        let matches = components.queryItems?.filter { $0.name == name } ?? []
        guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
        return value
    }
}
