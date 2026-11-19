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
                    continuation.resume(throwing: PulseCloudAuthError.googleSignIn)
                }
            }
            session.presentationContextProvider = self
            browser = session
            if !session.start() { continuation.resume(throwing: PulseCloudAuthError.googleSignIn) }
        }
        switch authorization.callback(callback) {
        case .authorized(let requestURI): return requestURI
        case .cancelled: throw CancellationError()
        case .invalid: throw PulseCloudAuthError.googleSignIn
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
