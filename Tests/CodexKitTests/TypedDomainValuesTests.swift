@testable import CodexKit
import XCTest

final class TypedDomainValuesTests: XCTestCase {
    func testSearchProgressKeepsUnknownProviderStates() {
        let progress = AgentProgress.webSearch(itemID: "search", status: "future_state", action: nil)
        guard case let .webSearch(_, status, _) = progress else { return XCTFail("Expected search progress") }
        XCTAssertEqual(status, .custom("future_state"))
        XCTAssertEqual(status.rawValue, "future_state")
    }

    func testKnownAndCustomRuntimeCodesKeepTheirExistingWireRepresentation() throws {
        let known = AgentRuntimeError(code: .quotaExceeded, message: "Quota exhausted")
        let object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(known))
        XCTAssertEqual(object.objectValue?["code"], .string("quota_exceeded"))
        XCTAssertEqual(known.knownCode, .quotaExceeded)

        let legacy = Data(#"{"code":"application_specific_failure","message":"Custom"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentRuntimeError.self, from: legacy)
        XCTAssertNil(decoded.knownCode)
        XCTAssertEqual(decoded.code, "application_specific_failure")
        XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeError.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testLegacyStoreDiagnosticsDecodeKnownAndCustomImplementations() throws {
        for (name, expected) in [("sqlite", MemoryStoreImplementation.sqlite),
                                 ("realm", .realm), ("in_memory", .inMemory), ("external-store", .custom("external-store"))] {
            let data = Data("""
                {"namespace":"test","implementation":"\(name)","totalRecords":0,
                 "activeRecords":0,"archivedRecords":0,"countsByScope":[],"countsByCategory":{}}
                """.utf8)
            let decoded = try JSONDecoder().decode(MemoryStoreDiagnostics.self, from: data)
            XCTAssertEqual(decoded.implementation, expected)
            let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
            XCTAssertEqual(encoded.objectValue?["implementation"], .string(name))
        }
    }
}
