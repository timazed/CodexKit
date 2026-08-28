@testable import CodexKit
import Foundation
import XCTest

final class CodexResponsesLiveRecoveryTests: XCTestCase {
    func testChatGPTCodexEndpointResumesStoredBackgroundResponse() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXKIT_RUN_LIVE_RECOVERY_TEST"] == "1" else {
            throw XCTSkip(
                "Set CODEXKIT_RUN_LIVE_RECOVERY_TEST=1 to run the live recovery probe."
            )
        }

        let accessToken = try requiredEnvironmentValue(
            "CODEXKIT_LIVE_ACCESS_TOKEN",
            in: environment
        )
        let accountID = try requiredEnvironmentValue(
            "CODEXKIT_LIVE_ACCOUNT_ID",
            in: environment
        )
        let model = environment["CODEXKIT_LIVE_MODEL"] ?? "gpt-5.6-sol"
        let baseURL = try liveBaseURL(from: environment)
        let threadID = "codexkit-live-recovery-\(UUID().uuidString)"

        let configuration = CodexResponsesBackendConfiguration(
            baseURL: baseURL,
            model: model,
            reasoningEffort: .low,
            instructions: "Follow the user's request exactly. Do not use tools.",
            executionMode: .resumableBackground,
            requestRetryPolicy: .disabled
        )
        let requestFactory = CodexResponsesRequestFactory(
            configuration: configuration,
            encoder: JSONEncoder()
        )
        let streamClient = CodexResponsesEventStreamClient(
            urlSession: liveURLSession(),
            decoder: JSONDecoder(),
            logger: AgentLogger(configuration: .disabled)
        )
        let session = ChatGPTSession(
            accessToken: accessToken,
            account: ChatGPTAccount(id: accountID, email: "", plan: .unknown),
            isExternallyManaged: true
        )
        let createRequest = try requestFactory.buildURLRequest(
            threadConfiguration: AgentThreadConfiguration(
                model: model,
                reasoningEffort: .low
            ),
            instructions: configuration.instructions,
            responseContract: nil,
            threadID: threadID,
            items: [
                .userMessage(
                    AgentMessage(
                        threadID: threadID,
                        role: .user,
                        text: "List the integers 1 through 200, then write CODEXKIT_RECOVERY_COMPLETE."
                    )
                ),
            ],
            tools: [],
            session: session
        )

        let checkpoint: LiveRecoveryCheckpoint
        do {
            checkpoint = try await disconnectAfterResponseCreated(
                request: createRequest,
                using: streamClient
            )
        } catch let error as AgentRuntimeError where error.code == "responses_http_status_400" {
            XCTFail(
                "The endpoint rejected stored background response creation; exact response "
                    + "recovery is unavailable. Endpoint response: \(error.message)"
            )
            return
        }
        let resumeRequest = try requestFactory.buildResumeURLRequest(
            responseID: checkpoint.responseID,
            startingAfter: checkpoint.sequenceNumber,
            threadID: threadID,
            session: session
        )
        let resumedStream = try await streamClient.streamEvents(request: resumeRequest)

        var receivedEventAfterCursor = false
        var receivedOutput = false
        var completedResponseID: String?
        for try await event in resumedStream {
            if let sequenceNumber = event.sequenceNumber {
                XCTAssertGreaterThan(
                    sequenceNumber,
                    checkpoint.sequenceNumber,
                    "The recovery endpoint replayed an event at or before starting_after."
                )
                receivedEventAfterCursor = true
            }
            switch event.kind {
            case .assistantTextDelta, .outputItem:
                receivedOutput = true
            case let .completed(_, responseID):
                completedResponseID = responseID
            default:
                break
            }
        }

        XCTAssertTrue(receivedEventAfterCursor)
        XCTAssertTrue(receivedOutput)
        XCTAssertEqual(completedResponseID, checkpoint.responseID)
    }
}

private struct LiveRecoveryCheckpoint {
    let responseID: String
    let sequenceNumber: Int
}

private func disconnectAfterResponseCreated(
    request: URLRequest,
    using client: CodexResponsesEventStreamClient
) async throws -> LiveRecoveryCheckpoint {
    let stream = try await client.streamEvents(request: request)
    for try await event in stream {
        guard case let .responseCreated(responseID) = event.kind,
              let responseID,
              !responseID.isEmpty else {
            continue
        }
        return LiveRecoveryCheckpoint(
            responseID: responseID,
            sequenceNumber: event.sequenceNumber ?? 0
        )
    }
    throw AgentRuntimeError(
        code: "live_recovery_response_id_missing",
        message: "The live endpoint ended the create stream without a response.created identifier."
    )
}

private func requiredEnvironmentValue(
    _ name: String,
    in environment: [String: String]
) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
        throw AgentRuntimeError(
            code: "live_recovery_environment_missing",
            message: "Set \(name) before running the live recovery probe."
        )
    }
    return value
}

private func liveBaseURL(from environment: [String: String]) throws -> URL {
    let value = environment["CODEXKIT_LIVE_BASE_URL"]
        ?? "https://chatgpt.com/backend-api/codex"
    guard let url = URL(string: value) else {
        throw AgentRuntimeError(
            code: "live_recovery_base_url_invalid",
            message: "CODEXKIT_LIVE_BASE_URL is not a valid URL."
        )
    }
    return url
}

private func liveURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    return URLSession(configuration: configuration)
}
