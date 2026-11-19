import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "StrandiOS" / "CloudBackup"
SWIFTC = shutil.which("swiftc")

CALLBACK_TESTS = r"""
import Foundation

func googleURL(state: String = "random+state", redirect: String = PulseGoogleOAuth.redirectURI) -> URL {
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirect),
        URLQueryItem(name: "state", value: state)
    ]
    return components.url!
}

let flow = PulseGoogleOAuth(authorizationURL: googleURL(), sessionID: "firebase-session")!
precondition(flow.sessionID == "firebase-session")
let query = "code=4%2Fcode%2Bencoded&state=random%2Bstate&scope=openid+email"
let native = "pulseauth://google/callback?"
let callbackURL = URL(string: native + query)!
let requestURI = URL(string: PulseGoogleOAuth.redirectURI + "?" + query)!
precondition(flow.callback(callbackURL) == .authorized(requestURI))
guard case .authorized(let forwarded) = flow.checkedCallback(callbackURL) else { fatalError("Valid callback") }
precondition(forwarded.absoluteString == PulseGoogleOAuth.redirectURI + "?" + query)
let bareFragment = URL(string: native + query + "#")!
guard case .authorized(let fromBareFragment) = flow.checkedCallback(bareFragment) else {
    fatalError("An empty fragment does not affect a valid callback")
}
precondition(fromBareFragment.absoluteString == forwarded.absoluteString)
let cancelled = URL(string: native + "error=access_denied&state=random%2Bstate")!
precondition(flow.callback(cancelled) == .cancelled && flow.checkedCallback(cancelled) == .cancelled)
let invalid: [(String, PulseGoogleOAuth.CallbackFailure)] = [
    (native + "code=other", .stateMissing),
    (native + "code=other&state=", .stateMissing),
    (native + "code=other&state=other", .stateMismatch),
    (native + "code=other&state=other#", .stateMismatch),
    (native + "error=access_denied&state=other", .stateMismatch),
    (native + "error=temporary_error&error_description=provider-detail&state=random%2Bstate", .providerError),
    (native + "error=&state=random%2Bstate", .providerError),
    (native + "state=random%2Bstate", .codeMissing),
    (native + "code=&state=random%2Bstate", .codeMissing),
    (native + query + "&st%61te=random%2Bstate", .ambiguousParameters),
    (native + query + "&code=duplicate", .ambiguousParameters),
    (native + query + "&error=", .ambiguousParameters),
    (native + "error=access_denied&error=access_denied&state=random%2Bstate", .ambiguousParameters),
    (native + query + "#fragment", .endpointMismatch),
    (native + query + "#%20", .endpointMismatch),
    ("pulseauth://fake/callback?" + query, .endpointMismatch),
    ("pulseauth://google:443/callback?" + query, .endpointMismatch),
    ("pulseauth://google/call%62ack?" + query, .endpointMismatch),
    ("https://pulse.joliveira.xyz/auth/google/callback?" + query, .endpointMismatch)
]
for (url, reason) in invalid {
    let callback = URL(string: url)!
    precondition(flow.callback(callback) == .invalid)
    precondition(flow.checkedCallback(callback) == .rejected(reason))
}
precondition(PulseGoogleOAuth(authorizationURL: googleURL(), sessionID: "") == nil)
precondition(PulseGoogleOAuth(authorizationURL: googleURL(state: ""), sessionID: "session") == nil)
precondition(PulseGoogleOAuth(authorizationURL: googleURL(redirect: "https://other.example"), sessionID: "session") == nil)
let foreignURL = URL(string: googleURL().absoluteString.replacingOccurrences(
    of: "accounts.google.com", with: "accounts.google.com.other.example"
))!
precondition(PulseGoogleOAuth(authorizationURL: foreignURL, sessionID: "session") == nil)

let policy = PulseCloudBackupPolicy.self
precondition(policy.sameAccount(expectedID: "uid", expectedEmail: "OWNER@example.test",
                                id: "uid", email: "owner@example.test"))
precondition(!policy.sameAccount(expectedID: "uid", expectedEmail: "owner@example.test",
                                 id: "other-uid", email: "owner@example.test"))
precondition(!policy.sameAccount(expectedID: "uid", expectedEmail: "owner@example.test",
                                 id: "uid", email: "someone@example.test"))
precondition(!policy.sameAccount(expectedID: "uid", expectedEmail: "", id: "uid", email: ""))
"""

REQUEST_TESTS = r"""
final class FirebaseStub: URLProtocol {
    static var responses: [(String, [String: Any], [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (operation, expected, response) = Self.responses.removeFirst()
        precondition(request.url?.host == "identitytoolkit.googleapis.com")
        precondition(request.url?.path == "/v1/accounts:\(operation)")
        precondition(request.httpMethod == "POST")
        let stream = request.httpBodyStream!
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            data.append(contentsOf: buffer.prefix(count))
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! NSDictionary
        precondition(body == expected as NSDictionary)
        let result = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: result, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func token(verified: Bool, provider: String = "password") -> String {
    let body: [String: Any] = [
        "email_verified": verified,
        "firebase": ["sign_in_provider": provider]
    ]
    let component = try! JSONSerialization.data(withJSONObject: body).base64EncodedString()
    return "firebase.\(component).signature"
}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FirebaseStub.self]
let auth = PulseCloudAuth(apiKey: "test-key", session: URLSession(configuration: configuration))
let verified = token(verified: true)
let googleToken = token(verified: true, provider: "google.com")
let email = "owner@example.test"
let credentialResponse: [String: Any] = [
    "localId": "existing", "email": email, "idToken": verified, "refreshToken": "password-refresh", "expiresIn": "3600"
]
let googleResponse: [String: Any] = [
    "providerId": "google.com", "localId": "existing", "email": email, "idToken": googleToken,
    "refreshToken": "google-refresh", "expiresIn": "3600"
]
FirebaseStub.responses = [
    ("createAuthUri", [
        "providerId": "google.com", "continueUri": PulseGoogleOAuth.redirectURI,
        "authFlowType": "CODE_FLOW", "oauthScope": "openid email", "customParameter": ["prompt": "select_account"]
    ], ["authUri": googleURL().absoluteString, "sessionId": "firebase-session"]),
    ("signInWithIdp", [
        "requestUri": requestURI.absoluteString, "sessionId": "firebase-session",
        "returnSecureToken": true, "returnIdpCredential": true, "autoCreate": true
    ], ["providerId": "google.com", "email": email, "needConfirmation": true, "pendingToken": "pending-google"]),
    ("signInWithPassword", ["email": email, "password": "known-pulse-password", "returnSecureToken": true],
     credentialResponse),
    ("signInWithIdp", [
        "requestUri": "http://localhost", "idToken": verified, "returnSecureToken": true, "pendingToken": "pending-google"
    ], googleResponse),
    ("signInWithIdp", [
        "requestUri": requestURI.absoluteString, "sessionId": "firebase-session",
        "returnSecureToken": true, "returnIdpCredential": true, "autoCreate": false
    ], googleResponse),
    ("signUp", ["email": email, "idToken": googleToken, "password": "new-password", "returnSecureToken": true],
     credentialResponse)
]

let authorization = try await auth.googleAuthorization()
precondition(authorization.callback(callbackURL) == .authorized(requestURI))
let first = try await auth.authenticateGoogle(requestURI: requestURI, sessionID: authorization.sessionID)
guard case .confirmPassword(let link) = first else { fatalError("Expected Firebase account confirmation") }
let existing = try await auth.authenticate(email: link.email, password: "known-pulse-password", create: false)
let unverified = PulseCloudCredential(account: existing.account, idToken: token(verified: false), expiresAt: Date())
do {
    _ = try await auth.linkGoogle(link, to: unverified)
    fatalError("Unverified existing account must not link")
} catch PulseCloudAuthError.verifyBeforeLinking {}
let mismatchedEmail = PulseCloudAccount(id: "existing", email: "different@example.test", refreshToken: "none")
let wrongAccount = PulseCloudCredential(account: mismatchedEmail, idToken: verified, expiresAt: Date())
do {
    _ = try await auth.linkGoogle(link, to: wrongAccount)
    fatalError("Different email must not link")
} catch PulseCloudAuthError.differentAccount {}
let linked = try await auth.linkGoogle(link, to: existing)
precondition(linked.account.id == existing.account.id)
precondition(linked.signInMethods == [.google, .password])

let reconfirmed = try await auth.authenticateGoogle(
    requestURI: requestURI, sessionID: authorization.sessionID, existingOnly: true)
guard case .signedIn(let google) = reconfirmed else { fatalError("Expected existing account to reauthenticate") }
let added = try await auth.addPassword("new-password", to: google)
precondition(added.account.id == google.account.id)
precondition(added.signInMethods == [.google, .password])
precondition(FirebaseStub.responses.isEmpty)
"""


@unittest.skipUnless(SWIFTC, "Requires Swift to exercise the OAuth policies")
class PulseGoogleAuthTests(unittest.TestCase):
    def run_swift(self, tests, extra_sources=()):
        with tempfile.TemporaryDirectory(prefix="pulse-google-auth-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(tests, encoding="utf-8")
            executable = directory / "verify"
            subprocess.run(
                [
                    SWIFTC,
                    "-module-cache-path", str(directory / "modules"),
                    str(SOURCE / "PulseGoogleOAuth.swift"),
                    str(SOURCE / "PulseCloudBackupPolicy.swift"),
                    *(str(SOURCE / name) for name in extra_sources),
                    str(main),
                    "-o", str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable)], check=True)

    def test_validates_callback_and_account_identity(self):
        self.run_swift(CALLBACK_TESTS)

    @unittest.skipUnless(sys.platform == "darwin", "Firebase auth uses the Apple Security framework")
    def test_firebase_requests_keep_google_and_password_on_one_uid(self):
        self.run_swift(CALLBACK_TESTS + REQUEST_TESTS, ("PulseCloudAuth.swift",))
