import Foundation
import Security

enum PulseCloudSignInMethod: String, Codable, Sendable {
    case password
    case google = "google.com"
}

struct PulseCloudAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let refreshToken: String
    var signInMethods: Set<PulseCloudSignInMethod>? = nil
}

struct PulseCloudCredential: Sendable {
    var account: PulseCloudAccount
    let idToken: String
    let expiresAt: Date

    private var claims: [String: Any]? {
        let pieces = idToken.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var payload = pieces[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // Firebase's token is returned directly by the account service. The backup API
    // independently verifies the signature and claims before granting access.
    var emailVerified: Bool { claims?["email_verified"] as? Bool == true }
    var signInMethods: Set<PulseCloudSignInMethod> {
        var methods = account.signInMethods ?? []
        if let firebase = claims?["firebase"] as? [String: Any] {
            if let providerID = firebase["sign_in_provider"] as? String,
               let method = PulseCloudSignInMethod(rawValue: providerID) {
                methods.insert(method)
            }
            if let identities = firebase["identities"] as? [String: Any], identities["google.com"] != nil {
                methods.insert(.google)
            }
        }
        return methods
    }
}

struct PulseGoogleLink: Sendable {
    enum Credential: Sendable {
        case pendingToken(String)
        case idToken(String)
        case accessToken(String)
    }

    let email: String
    let credential: Credential
}

enum PulseGoogleResult: Sendable {
    case signedIn(PulseCloudCredential)
    case confirmPassword(PulseGoogleLink)
}

enum PulseCloudAuthError: LocalizedError {
    case notConfigured
    case invalidResponse
    case googleSignIn
    case differentAccount
    case verifyBeforeLinking
    case keychain(OSStatus)
    case firebase(String)

    var firebaseCode: String? {
        guard case let .firebase(code) = self else { return nil }
        return code
    }

    var sessionExpired: Bool {
        guard case let .firebase(code) = self else { return false }
        return ["USER_NOT_FOUND", "USER_DISABLED", "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN",
                "INVALID_GRANT", "INVALID_ID_TOKEN"].contains(code)
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Pulse Account is unavailable in this build.")
        case .invalidResponse: String(localized: "The account service returned an unexpected response.")
        case .googleSignIn: String(localized: "Google sign-in couldn’t be completed. Try again.")
        case .differentAccount: String(localized: "Choose the Google account that matches your Pulse account.")
        case .verifyBeforeLinking: String(localized: "Verify your Pulse email before connecting Google sign-in.")
        case .keychain: String(localized: "Pulse couldn’t access secure storage. Unlock your iPhone and try again.")
        case .firebase(let code):
            switch code {
            case "INVALID_EMAIL": String(localized: "Enter a valid email address.")
            case "EMAIL_EXISTS":
                String(localized: "That email already has an account. Sign in with Google, enter your password, or reset it.")
            case "FEDERATED_USER_ID_ALREADY_LINKED", "EMAIL_ALREADY_IN_USE":
                String(localized: "That Google sign-in is already connected to a different account.")
            case "INVALID_IDP_RESPONSE", "INVALID_PENDING_TOKEN", "INVALID_SESSION_ID":
                String(localized: "Google sign-in expired. Start again to reconnect.")
            case "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD", "EMAIL_NOT_FOUND":
                String(localized: "The email or password is incorrect.")
            case "WEAK_PASSWORD", "PASSWORD_DOES_NOT_MEET_REQUIREMENTS":
                String(localized: "Choose a stronger password.")
            case "TOO_MANY_ATTEMPTS_TRY_LATER":
                String(localized: "Too many attempts. Try again in a few minutes.")
            case "USER_DISABLED", "USER_NOT_FOUND", "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN",
                 "INVALID_GRANT", "INVALID_ID_TOKEN", "CREDENTIAL_TOO_OLD_LOGIN_AGAIN":
                String(localized: "Your session expired. Sign in again.")
            default: String(localized: "The account service couldn’t complete the request. Try again.")
            }
        }
    }
}

/// Firebase Authentication without an SDK that starts networking at launch.
struct PulseCloudAuth: Sendable {
    static let apiKey: String? = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PulseFirebaseAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.hasPrefix("AIza") else { return nil }
        return value
    }()

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private let apiKey: String?
    private let session: URLSession

    init(apiKey: String? = Self.apiKey, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session ?? Self.defaultSession
    }

    func authenticate(email: String, password: String, create: Bool) async throws -> PulseCloudCredential {
        let response: SignInResponse = try await identity(
            create ? "signUp" : "signInWithPassword",
            body: ["email": email, "password": password, "returnSecureToken": true])
        return PulseCloudCredential(
            account: PulseCloudAccount(id: response.localId, email: response.email, refreshToken: response.refreshToken,
                                       signInMethods: [.password]),
            idToken: response.idToken, expiresAt: try expiry(response.expiresIn))
    }

    func googleAuthorization() async throws -> PulseGoogleOAuth {
        let response: AuthorizationResponse = try await identity("createAuthUri", body: [
            "providerId": PulseGoogleOAuth.provider,
            "continueUri": PulseGoogleOAuth.redirectURI,
            "authFlowType": "CODE_FLOW",
            "oauthScope": "openid email",
            "customParameter": ["prompt": "select_account"]
        ])
        guard let flow = PulseGoogleOAuth(authorizationURL: response.authUri, sessionID: response.sessionId) else {
            throw PulseCloudAuthError.googleSignIn
        }
        return flow
    }

    func authenticateGoogle(
        requestURI: URL, sessionID: String, existingOnly: Bool = false
    ) async throws -> PulseGoogleResult {
        let response: GoogleResponse
        do {
            response = try await identity("signInWithIdp", body: [
                "requestUri": requestURI.absoluteString, "sessionId": sessionID,
                "returnSecureToken": true, "returnIdpCredential": true, "autoCreate": !existingOnly
            ])
        } catch let error as PulseCloudAuthError where existingOnly && error.sessionExpired {
            throw PulseCloudAuthError.differentAccount
        }
        if response.needConfirmation == true || response.errorMessage == "EMAIL_EXISTS" {
            guard !existingOnly, response.providerId == PulseGoogleOAuth.provider,
                  let email = response.email, !email.isEmpty, let credential = response.linkCredential else {
                throw PulseCloudAuthError.differentAccount
            }
            return .confirmPassword(PulseGoogleLink(email: email, credential: credential))
        }
        do {
            return .signedIn(try googleCredential(response))
        } catch let error as PulseCloudAuthError where existingOnly && error.sessionExpired {
            throw PulseCloudAuthError.differentAccount
        }
    }

    func linkGoogle(_ link: PulseGoogleLink, to existing: PulseCloudCredential) async throws -> PulseCloudCredential {
        guard PulseCloudBackupPolicy.sameEmail(existing.account.email, link.email) else {
            throw PulseCloudAuthError.differentAccount
        }
        guard existing.emailVerified else { throw PulseCloudAuthError.verifyBeforeLinking }
        var body: [String: Any] = [
            "requestUri": "http://localhost", "idToken": existing.idToken, "returnSecureToken": true
        ]
        switch link.credential {
        case .pendingToken(let token):
            body["pendingToken"] = token
        case .idToken(let token):
            body["postBody"] = try googlePostBody(name: "id_token", token: token)
        case .accessToken(let token):
            body["postBody"] = try googlePostBody(name: "access_token", token: token)
        }
        let response: GoogleResponse = try await identity("signInWithIdp", body: body)
        var linked = try googleCredential(response)
        try requireSameAccount(linked, as: existing.account)
        linked.account.signInMethods = [.password, .google]
        return linked
    }

    func addPassword(_ password: String, to existing: PulseCloudCredential) async throws -> PulseCloudCredential {
        guard existing.emailVerified else { throw PulseCloudAuthError.verifyBeforeLinking }
        // Set the password on the existing account without submitting an email address.
        let response: SignInResponse = try await identity("update", body: [
            "idToken": existing.idToken, "password": password, "returnSecureToken": true
        ])
        var linked = PulseCloudCredential(
            account: PulseCloudAccount(id: response.localId, email: response.email, refreshToken: response.refreshToken,
                                       signInMethods: existing.signInMethods),
            idToken: response.idToken, expiresAt: try expiry(response.expiresIn))
        try requireSameAccount(linked, as: existing.account)
        if !linked.emailVerified {
            linked = try await refresh(linked.account)
            try requireSameAccount(linked, as: existing.account)
        }
        guard linked.emailVerified else { throw PulseCloudAuthError.invalidResponse }
        let user = try await lookupAccount(linked)
        let methods = user.listedMethods
        guard methods.isSuperset(of: [.google, .password]) else { throw PulseCloudAuthError.invalidResponse }
        linked.account.signInMethods = methods
        return linked
    }

    func resolveAccountMethods(_ credential: PulseCloudCredential) async throws -> PulseCloudCredential {
        let user = try await lookupAccount(credential)
        var resolved = credential
        var methods = user.listedMethods
        if (user.passwordUpdatedAt ?? 0) > 0 { methods.insert(.password) }
        resolved.account.signInMethods = methods
        return resolved
    }

    private func lookupAccount(_ credential: PulseCloudCredential) async throws -> LookupResponse.User {
        let response: LookupResponse = try await identity("lookup", body: ["idToken": credential.idToken])
        guard response.users.count == 1, let user = response.users.first,
              user.localId == credential.account.id,
              PulseCloudBackupPolicy.sameEmail(user.email, credential.account.email) else {
            throw PulseCloudAuthError.invalidResponse
        }
        return user
    }

    func requireSameAccount(_ credential: PulseCloudCredential, as account: PulseCloudAccount) throws {
        guard PulseCloudBackupPolicy.sameAccount(expectedID: account.id, expectedEmail: account.email,
                                                  id: credential.account.id, email: credential.account.email) else {
            throw PulseCloudAuthError.differentAccount
        }
    }

    func refresh(_ account: PulseCloudAccount) async throws -> PulseCloudCredential {
        var request = try requestURL(host: "securetoken.googleapis.com", path: "/v1/token")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let token = account.refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PulseCloudAuthError.invalidResponse
        }
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(token)".utf8)
        let response: RefreshResponse = try await perform(request)
        guard response.userID == account.id else { throw PulseCloudAuthError.invalidResponse }
        return PulseCloudCredential(
            account: PulseCloudAccount(id: account.id, email: account.email, refreshToken: response.refreshToken,
                                       signInMethods: account.signInMethods),
            idToken: response.idToken, expiresAt: try expiry(response.expiresIn))
    }

    func sendVerification(idToken: String) async throws {
        let _: EmptyResponse = try await identity("sendOobCode", body: [
            "requestType": "VERIFY_EMAIL", "idToken": idToken
        ])
    }

    func sendPasswordReset(email: String) async throws {
        do {
            let _: EmptyResponse = try await identity("sendOobCode", body: [
                "requestType": "PASSWORD_RESET", "email": email
            ])
        } catch PulseCloudAuthError.firebase("EMAIL_NOT_FOUND") {
            // Return the same result whether the email belongs to an existing account.
        }
    }

    func deleteAccount(idToken: String) async throws {
        let _: EmptyResponse = try await identity("delete", body: ["idToken": idToken])
    }

    private func googleCredential(_ response: GoogleResponse) throws -> PulseCloudCredential {
        if let error = response.errorMessage, !error.isEmpty { throw PulseCloudAuthError.firebase(error) }
        guard response.providerId == PulseGoogleOAuth.provider, response.emailRecycled != true,
              let id = response.localId, !id.isEmpty, let email = response.email, !email.isEmpty,
              let idToken = response.idToken, !idToken.isEmpty, let refreshToken = response.refreshToken,
              !refreshToken.isEmpty, let expiresIn = response.expiresIn else {
            throw PulseCloudAuthError.invalidResponse
        }
        let primaryEmail = response.originalEmail.flatMap { $0.isEmpty ? nil : $0 } ?? email
        guard PulseCloudBackupPolicy.sameEmail(email, primaryEmail) else {
            throw PulseCloudAuthError.differentAccount
        }
        let credential = PulseCloudCredential(
            account: PulseCloudAccount(id: id, email: primaryEmail, refreshToken: refreshToken, signInMethods: [.google]),
            idToken: idToken, expiresAt: try expiry(expiresIn))
        guard credential.emailVerified else { throw PulseCloudAuthError.verifyBeforeLinking }
        return credential
    }

    private func googlePostBody(name: String, token: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let escaped = token.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PulseCloudAuthError.invalidResponse
        }
        return "\(name)=\(escaped)&providerId=\(PulseGoogleOAuth.provider)"
    }

    private func identity<T: Decodable>(_ operation: String, body: [String: Any]) async throws -> T {
        var request = try requestURL(host: "identitytoolkit.googleapis.com", path: "/v1/accounts:\(operation)")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                         forHTTPHeaderField: "X-Firebase-Locale")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func requestURL(host: String, path: String) throws -> URLRequest {
        guard let apiKey else { throw PulseCloudAuthError.notConfigured }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw PulseCloudAuthError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PulseCloudAuthError.invalidResponse }
        guard 200..<300 ~= response.statusCode else {
            let raw = (try? JSONDecoder().decode(FirebaseError.self, from: data))?.error.message ?? ""
            let code = raw.components(separatedBy: " : ").first ?? raw
            throw PulseCloudAuthError.firebase(code)
        }
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func expiry(_ raw: String) throws -> Date {
        guard let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 else {
            throw PulseCloudAuthError.invalidResponse
        }
        return Date().addingTimeInterval(seconds)
    }

    private struct EmptyResponse: Decodable {}
    private struct FirebaseError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
    private struct SignInResponse: Decodable {
        let idToken: String
        let email: String
        let refreshToken: String
        let expiresIn: String
        let localId: String
    }
    private struct AuthorizationResponse: Decodable {
        let authUri: URL
        let sessionId: String
    }
    private struct GoogleResponse: Decodable {
        let providerId: String?
        let email: String?
        let originalEmail: String?
        let localId: String?
        let idToken: String?
        let refreshToken: String?
        let expiresIn: String?
        let emailRecycled: Bool?
        let needConfirmation: Bool?
        let errorMessage: String?
        let pendingToken: String?
        let oauthIdToken: String?
        let oauthAccessToken: String?

        var linkCredential: PulseGoogleLink.Credential? {
            if let pendingToken, !pendingToken.isEmpty { return .pendingToken(pendingToken) }
            if let oauthIdToken, !oauthIdToken.isEmpty { return .idToken(oauthIdToken) }
            if let oauthAccessToken, !oauthAccessToken.isEmpty { return .accessToken(oauthAccessToken) }
            return nil
        }
    }
    private struct LookupResponse: Decodable {
        struct User: Decodable {
            struct Provider: Decodable { let providerId: String }
            let localId: String
            let email: String
            let providerUserInfo: [Provider]?
            let passwordUpdatedAt: Double?

            var listedMethods: Set<PulseCloudSignInMethod> {
                Set((providerUserInfo ?? []).compactMap { PulseCloudSignInMethod(rawValue: $0.providerId) })
            }
        }
        let users: [User]
    }
    private struct RefreshResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
        let userID: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case userID = "user_id"
        }
    }
}

enum PulseCloudSecureStore {
    private static func query(name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "xyz.joliveira.pulse.backup.session",
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load<Value: Decodable>(_ type: Value.Type, name: String) throws -> Value? {
        var read = query(name: name)
        read[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data else {
            throw PulseCloudAuthError.keychain(status)
        }
        return try JSONDecoder().decode(type, from: bytes)
    }

    static func save<Value: Encodable>(_ value: Value, name: String) throws {
        let match = query(name: name)
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = match
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw PulseCloudAuthError.keychain(result) }
        } else if status != errSecSuccess {
            throw PulseCloudAuthError.keychain(status)
        }
    }

    static func remove(name: String) throws {
        let status = SecItemDelete(query(name: name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PulseCloudAuthError.keychain(status)
        }
    }
}
