@testable import CodexKit
import XCTest

final class ExternalSessionDiscoveryTests: XCTestCase {
    func testFileAndKeychainDiscoveryDiscardOwnerSecrets() async throws {
        for storage in [CodexCredentialStorage.file, .keyring, .auto] {
            let store = ExternalFixtureStore()
            let data = try externalPayload(mode: nil)
            if storage == .file { store.setFile(data) } else { store.setKeychain(data) }
            let source = source(store, storage: storage)
            let session = try await source.discover()
            XCTAssertTrue(session.isExternallyManaged)
            XCTAssertNil(session.refreshToken)
            XCTAssertNil(session.idToken)
            XCTAssertEqual(session.binding.userID, "user")
            XCTAssertEqual(session.account.id, "workspace")
            if storage != .file {
                XCTAssertEqual(store.queries.first?.0, "Codex Auth")
                XCTAssertEqual(store.queries.first?.1, "cli|" + String(CodexLocalSessionSource.digest("/fixture/codex").prefix(16)))
            }
            XCTAssertEqual(store.counts.writes, 0)
            XCTAssertEqual(store.counts.deletes, 0)
        }
    }

    func testAutoFallbackDoesNotMaskDenialOrMigrateAnExistingBinding() async throws {
        let store = ExternalFixtureStore()
        store.setFile(try externalPayload())
        let source = source(store, storage: .auto)
        _ = try await source.discover()
        store.setKeychain(try externalPayload())
        await expect(.configurationChanged) { _ = try await source.resolve() }
        store.setKeychain(nil, error: .accessDenied)
        await expect(.accessDenied) { _ = try await self.source(store, storage: .auto).resolve() }
        store.setKeychain(nil, error: .storageUnavailable)
        _ = try await self.source(store, storage: .auto).discover()
        store.setKeychain(try externalPayload())
        let boundKeychain = self.source(store, storage: .auto)
        _ = try await boundKeychain.discover()
        store.setKeychain(nil)
        await expect(.missingCredentials) { _ = try await boundKeychain.resolve() }
    }

    func testTypedFailuresAndExpiredSnapshotForRenewal() async throws {
        let store = ExternalFixtureStore()
        let source = source(store)
        await expect(.missingCredentials) { _ = try await source.discover() }
        store.setFile(nil, error: .accessDenied)
        await expect(.accessDenied) { _ = try await source.discover() }
        store.setFile(Data("{private malformed".utf8))
        await expect(.malformedCredentials) { _ = try await source.discover() }
        store.setFile(try externalPayload(mode: "apikey"))
        await expect(.unsupportedAuthentication) { _ = try await source.discover() }
        store.setFile(try externalPayload(tokenAccount: "different"))
        await expect(.accountChanged) { _ = try await source.discover() }
        store.setFile(try externalPayload(expiry: Date().addingTimeInterval(-60)))
        await expect(.expiredCredentials) { _ = try await source.discover() }
        let expired = try await source.resolve()
        XCTAssertTrue(expired.requiresRefresh())
        await expect(.storageUnavailable) { _ = try await self.source(store, storage: .ephemeral).resolve() }
        let secrets = CodexLocalSessionSource(configuration: {
            .init(codexHome: URL(fileURLWithPath: "/fixture"), storage: .keyring, keyringBackend: .secrets)
        }, reader: store)
        await expect(.unsupportedStorage) { _ = try await secrets.resolve() }
    }

    func testWorkspaceRestrictionsAndConfigurationChange() async throws {
        let store = ExternalFixtureStore()
        store.setFile(try externalPayload())
        let denied = CodexLocalSessionSource(configuration: {
            .init(codexHome: URL(fileURLWithPath: "/fixture"), storage: .file, allowedWorkspaceIDs: ["other"])
        }, reader: store)
        await expect(.accountChanged) { _ = try await denied.resolve() }
        let config = ConfigurationBox()
        let source = CodexLocalSessionSource(configuration: { await config.value }, reader: store)
        _ = try await source.resolve()
        await config.change()
        await expect(.configurationChanged) { _ = try await source.resolve() }
    }

    func testMacOSReaderUsesOnlySyntheticFilesAndMapsMissing() throws {
        #if os(macOS)
        let reader = MacOSCodexCredentialReader()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try reader.readFile(root.appendingPathComponent("absent")))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("auth.json")
        let data = try externalPayload()
        try data.write(to: file)
        XCTAssertEqual(try reader.readFile(file), data)
        XCTAssertEqual(try Data(contentsOf: file), data)
        #endif
    }

    private func source(_ store: ExternalFixtureStore, storage: CodexCredentialStorage = .file) -> CodexLocalSessionSource {
        CodexLocalSessionSource(configuration: { .init(codexHome: URL(fileURLWithPath: "/fixture/codex"), storage: storage) }, reader: store)
    }

    private func expect(_ expected: ChatGPTSessionError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, expected) }
    }
}

private actor ConfigurationBox {
    var value = CodexLocalSessionConfiguration(codexHome: URL(fileURLWithPath: "/fixture"), storage: .file)
    func change() { value = .init(codexHome: URL(fileURLWithPath: "/other"), storage: .file) }
}
