import AuthenticationServices
import UIKit

@MainActor
final class PulseGoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var anchor: ASPresentationAnchor?
    private var browser: ASWebAuthenticationSession?

    func authorize(_ authorization: PulseGoogleOAuth) async throws -> URL {
        anchor = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }?
            .keyWindow
        guard anchor != nil else { throw PulseCloudAuthError.googleSignIn }
        defer {
            browser = nil
            anchor = nil
        }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorization.authorizationURL, callbackURLScheme: PulseGoogleOAuth.callbackScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let code = error.map { ($0 as NSError).code }
                    continuation.resume(throwing: SignInFailure.browser(code))
                }
            }
            session.presentationContextProvider = self
            browser = session
            if !session.start() { continuation.resume(throwing: PulseCloudAuthError.googleSignIn) }
        }
        switch authorization.checkedCallback(callback) {
        case .authorized(let requestURI): return requestURI
        case .cancelled: throw CancellationError()
        case .rejected(let reason): throw SignInFailure.callback(reason)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    /// Fixed support codes distinguish browser failures from response validation without
    /// exposing the callback URL, authorization code, state, or provider error description.
    private enum SignInFailure: LocalizedError {
        case browser(Int?)
        case callback(PulseGoogleOAuth.CallbackFailure)

        var errorDescription: String? {
            let code: String
            switch self {
            case .browser(let status): code = "browser.\(status.map(String.init) ?? "unknown")"
            case .callback(let reason): code = "callback.\(reason.rawValue)"
            }
            return String(localized: "Google sign-in couldn’t be completed. Try again.") + " [\(code)]"
        }
    }
}
