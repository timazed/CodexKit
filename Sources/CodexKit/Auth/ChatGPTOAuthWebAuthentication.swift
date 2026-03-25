import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AuthenticationServices)
@available(iOS 13.0, macOS 10.15, *)
public final class SystemChatGPTWebAuthenticationProvider: NSObject, ChatGPTWebAuthenticationProviding, @unchecked Sendable {
    private var activeSession: ASWebAuthenticationSession?
    private var activePresentationContextProvider: PresentationContextProvider?
    private let presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    public override convenience init() {
        self.init(presentationAnchorProvider: {
            defaultPresentationAnchor()
        })
    }

    public init(
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.presentationAnchorProvider = presentationAnchorProvider
        super.init()
    }

    public func authenticate(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        let anchor = try await MainActor.run { () throws -> ASPresentationAnchor in
            guard let anchor = presentationAnchorProvider() else {
                throw AgentRuntimeError(
                    code: "oauth_presentation_anchor_unavailable",
                    message: "The ChatGPT sign-in sheet could not be presented because no active window was available."
                )
            }
            return anchor
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [weak self] in
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    runAuthenticationCallbackOnMainActor { [weak self] in
                        self?.activeSession = nil
                        self?.activePresentationContextProvider = nil

                        if let callbackURL {
                            continuation.resume(returning: callbackURL)
                            return
                        }

                        continuation.resume(
                            throwing: error ?? AgentRuntimeError(
                                code: "oauth_authentication_cancelled",
                                message: "The ChatGPT sign-in flow did not complete."
                            )
                        )
                    }
                }
                let contextProvider = PresentationContextProvider(anchor: anchor)
                session.presentationContextProvider = contextProvider
                #if os(iOS)
                session.prefersEphemeralWebBrowserSession = false
                #endif
                self?.activeSession = session
                self?.activePresentationContextProvider = contextProvider

                guard session.start() else {
                    self?.activeSession = nil
                    self?.activePresentationContextProvider = nil
                    continuation.resume(
                        throwing: AgentRuntimeError(
                            code: "oauth_authentication_start_failed",
                            message: "The ChatGPT sign-in flow could not be started."
                        )
                    )
                    return
                }
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, *)
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

@MainActor
@available(iOS 13.0, macOS 10.15, *)
private func defaultPresentationAnchor() -> ASPresentationAnchor? {
    #if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }

    if let keyWindow = scenes
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) {
        return keyWindow
    }

    return scenes
        .flatMap(\.windows)
        .first(where: { !$0.isHidden })
    #elseif canImport(AppKit)
    return NSApp.keyWindow ?? NSApp.mainWindow
    #else
    return nil
    #endif
}
#endif

private struct UnsupportedChatGPTWebAuthenticationProvider: ChatGPTWebAuthenticationProviding {
    func authenticate(
        authorizeURL _: URL,
        callbackScheme _: String
    ) async throws -> URL {
        throw AgentRuntimeError(
            code: "oauth_authentication_unsupported",
            message: "Browser-based ChatGPT sign-in is not supported on this platform."
        )
    }
}
