@testable import CodexKit
import Foundation

final class ExternalFixtureStore: ChatGPTSessionStoring, CodexCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    var appSession: ChatGPTSession? { get { lock.withLock { storedSession } } set { lock.withLock { storedSession = newValue } } }
    private var storedSession: ChatGPTSession?
    private var fileData: Data?
    private var keychainData: Data?
    private var fileFailure: ChatGPTSessionError?
    private var keychainFailure: ChatGPTSessionError?
    private var writes = 0
    private var deletes = 0
    private var keychainQueries: [(String, String)] = []
    var counts: (writes: Int, deletes: Int) { lock.withLock { (writes, deletes) } }
    var queries: [(String, String)] { lock.withLock { keychainQueries } }
    func setFile(_ data: Data?, error: ChatGPTSessionError? = nil) { lock.withLock { fileData = data; fileFailure = error } }
    func setKeychain(_ data: Data?, error: ChatGPTSessionError? = nil) { lock.withLock { keychainData = data; keychainFailure = error } }
    func loadSession() throws -> ChatGPTSession? { appSession }
    func saveSession(_ session: ChatGPTSession) throws { lock.withLock { writes += 1; storedSession = session } }
    func deleteSession() throws { lock.withLock { deletes += 1; storedSession = nil } }
    func canonicalHome(_ home: URL) throws -> URL { home }
    func readFile(_ url: URL) throws -> Data? { try lock.withLock { if let fileFailure { throw fileFailure }; return fileData } }
    func readKeychain(service: String, account: String) throws -> Data? {
        try lock.withLock {
            keychainQueries.append((service, account))
            if let keychainFailure { throw keychainFailure }
            return keychainData
        }
    }
}

actor ExternalFixtureSource: ChatGPTExternalSessionSource {
    var session: ChatGPTSession
    var failure: ChatGPTSessionError?
    init(_ session: ChatGPTSession = externalSession()) { self.session = session }
    func set(_ session: ChatGPTSession) { self.session = session; failure = nil }
    func fail(_ error: ChatGPTSessionError) { failure = error }
    func resolve() async throws -> ChatGPTSession { if let failure { throw failure }; return session }
}

actor ExternalFixtureOwner: ChatGPTSessionOwnerRenewing {
    var requests = 0
    let action: @Sendable () async throws -> Void
    init(action: @escaping @Sendable () async throws -> Void) { self.action = action }
    func requestRenewal(for binding: ChatGPTSessionBinding) async throws { requests += 1; try await action() }
}

actor ExternalFixtureGate {
    var entered = false
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func open() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

final class ExternalFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

func externalSession(token: String = "borrowed-access", account: String = "workspace", user: String = "user",
                     source: String = "fixture", expiry: Date = Date().addingTimeInterval(3600)) -> ChatGPTSession {
    .init(accessToken: token, account: .init(id: account, email: "private@example.test", plan: .plus),
          binding: .init(sourceID: source, accountID: account, userID: user), expiresAt: expiry)
}

func externalPayload(account: String = "workspace", user: String = "user", expiry: Date = Date().addingTimeInterval(3600),
                     mode: String? = "chatgpt", tokenAccount: String? = nil) throws -> Data {
    let token = try makeUnsignedJWT(claims: ["exp": Int(expiry.timeIntervalSince1970), "email": "private@example.test",
        "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user, "chatgpt_plan_type": "plus"]])
    var value: [String: Any] = ["tokens": ["access_token": token, "id_token": token,
        "refresh_token": "NEVER-COPY-THIS-REFRESH-TOKEN", "account_id": tokenAccount ?? account]]
    if let mode { value["auth_mode"] = mode }
    return try JSONSerialization.data(withJSONObject: value)
}

func externalManager(store: ExternalFixtureStore = .init(), clock: ExternalFixtureClock? = nil,
                     timeout: Duration = .seconds(15)) -> ChatGPTSessionManager {
    .init(authProvider: DemoChatGPTAuthProvider(), sessionStore: store,
          now: { clock?.now() ?? Date() }, renewalTimeout: timeout)
}
