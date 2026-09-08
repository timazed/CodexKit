@testable import CodexKit
import Foundation
import XCTest

final class HistoryCursorEncodingTests: XCTestCase {
    func testSequenceCursorHasCanonicalKeyOrder() throws {
        let cursor = AgentHistoryCursor(threadID: "history:with:separators", sequenceNumber: 3)
        XCTAssertEqual(try jsonText(cursor),
            #"{"sequenceNumber":3,"threadID":"history:with:separators","version":1}"#)
    }

    func testSortedHistoryCursorHasCanonicalKeyOrder() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let record = AgentHistoryRecord(id: "record", sequenceNumber: 7, createdAt: date,
            item: .message(.init(id: "message", threadID: "thread", role: .user,
                text: "Example", createdAt: date)))
        let cursor = AgentHistoryCursor(threadID: "thread", record: record, sort: .createdAt(.descending))
        XCTAssertEqual(try jsonText(cursor),
            #"{"createdAt":0,"sequenceNumber":7,"sortField":"createdAt","sortOrder":"descending","threadID":"thread","version":2}"#)
    }

    func testPreviouslyIssuedUnsortedCursorsRemainReadable() throws {
        // These two encodings described the same page in the failing hosted run.
        let oldSequenceCursors = [
            "eyJzZXF1ZW5jZU51bWJlciI6MywidmVyc2lvbiI6MSwidGhyZWFkSUQiOiJoaXN0b3J5OndpdGg6c2VwYXJhdG9ycyJ9",
            "eyJ2ZXJzaW9uIjoxLCJzZXF1ZW5jZU51bWJlciI6MywidGhyZWFkSUQiOiJoaXN0b3J5OndpdGg6c2VwYXJhdG9ycyJ9",
        ]
        for raw in oldSequenceCursors {
            XCTAssertEqual(try AgentHistoryCursor(rawValue: raw)
                .decodedSequenceNumber(expectedThreadID: "history:with:separators"), 3)
        }
        let oldQueryJSON = #"{"version":2,"threadID":"thread","sortOrder":"descending","sortField":"createdAt","sequenceNumber":7,"createdAt":0}"#
        let oldQuery = AgentHistoryCursor(rawValue: Data(oldQueryJSON.utf8).base64EncodedString())
        let anchor = try oldQuery.decodedHistoryQueryAnchor(expectedThreadID: "thread", sort: .createdAt(.descending))
        XCTAssertEqual(anchor.sequenceNumber, 7)
        XCTAssertEqual(anchor.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }

    private func jsonText(_ cursor: AgentHistoryCursor) throws -> String {
        var base64 = cursor.rawValue.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
