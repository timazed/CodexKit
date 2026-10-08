#if DEBUG
import CodexKit
import Foundation

enum RemoteExecutionDemoProbe {
    typealias Progress = @Sendable (String) async -> Void

    static func run(baseURL: URL, mode: LocalCloudDemoMode, session: ChatGPTSession?, model: String,
                    scenarios: [RemoteDemoScenario], prompt: String, checkConflict: Bool = false,
                    progress: @escaping Progress = { _ in }) async throws -> RemoteDemoReport {
        _ = try LocalCloudDemoError.address(baseURL.absoluteString)
        let health = try JSONDecoder().decode(Health.self,
            from: await LocalCloudHTTP.data(for: URLRequest(url: baseURL.appendingPathComponent("health"))))
        guard health.mode == mode else { throw LocalCloudDemoError.mode }
        let authentication: CodexRemoteAuthentication
        if mode == .fixture {
            authentication = .init(accessToken: "synthetic-remote-demo", accountID: "remote-demo-fixture")
        } else {
            guard let session, session.expiresAt.map({ $0 > Date() }) ?? true else { throw LocalCloudDemoError.authentication }
            authentication = .init(session: session)
        }
        let device = UUID().uuidString
        let http = DemoHTTP(baseURL: baseURL, device: device)
        var submitted: [(RemoteDemoScenario, CodexRemoteExecution, CodexRemoteJob, CodexRemoteExecutionClient)] = []
        for scenario in scenarios {
            try Task.checkCancellation()
            var headers = ["x-demo-device": device, "x-demo-hold": "1"]
            if scenario.retry { headers["x-demo-retry-once"] = "1" }
            if scenario.legacyMetadata { headers["x-demo-legacy-job"] = "1" }
            let client = try CodexRemoteExecutionClient(baseURL: baseURL, headers: headers,
                retryPolicy: .init(initialBackoff: 0.05, maxBackoff: 0.1, jitterFactor: 0))
            let prepared = try RemoteDemoPreparedRequest.make(kind: scenario.kind, prompt: prompt, model: model)
            let execution = scenario.push.execution(prepared)
            // A host journal can restore the same selection before another submission.
            let restored = try JSONDecoder().decode(CodexRemoteExecution.self, from: JSONEncoder().encode(execution))
            try require(restored == execution, "The persisted execution changed.")
            await progress("Submitting \(scenario.kind.rawValue) · \(scenario.push.rawValue)\(scenario.retry ? " · retry enabled" : "")")
            let job = try await client.execute(remoteExecution: restored, authentication: authentication)
            try require(job.status == "queued" && job.completionPush == scenario.push.resolved,
                "Submission metadata did not preserve the preference.")
            submitted.append((scenario, restored, job, client))
            await progress("Queued \(job.jobID.prefix(8)) · middleware preference: \(job.completionPush.rawValue)")
        }
        let pending: RemoteDemoQueue = try await http.get("demo/queue")
        try require(pending.jobs.count == scenarios.count && pending.deliveries.isEmpty,
            "The middleware emitted a completion event before the batch finished.")
        if checkConflict, let (_, execution, _, client) = submitted.first {
            let changed = CodexRemoteExecution(preparedRequest: execution.preparedRequest,
                completionPush: execution.completionPush == .regular ? .silent : .regular)
            do {
                _ = try await client.execute(remoteExecution: changed, authentication: authentication)
                throw RemoteDemoFailure(message: "A changed preference incorrectly reused an existing request ID.")
            } catch let CodexRemoteExecutionError.http(failure) {
                try require(failure.statusCode == 409, "Expected HTTP 409 for the changed preference.")
            }
            await progress("Changed-preference retry rejected with HTTP 409")
        }
        let _: Released = try await http.get("demo/release", method: "POST")
        var results: [RemoteDemoResult] = []
        for (scenario, _, accepted, client) in submitted {
            var completed = false
            for _ in 0..<1_200 {
                try Task.checkCancellation()
                let job = try await client.job(id: accepted.jobID)
                try require(job.completionPush == scenario.push.resolved, "Status metadata changed the preference.")
                if job.status == "succeeded" { completed = true; break }
                if job.status == "failed" {
                    throw RemoteDemoFailure(message: "Remote job failed: \(job.failure?.code ?? "unknown").")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(completed, "Timed out waiting for the remote job.")
            let link: ResultLink = try await http.get("codex/\(accepted.jobID)/result")
            let expected = baseURL.appendingPathComponent("codex/\(accepted.jobID)/output")
            try require(link.jobId == accepted.jobID && URL(string: link.url) == expected, "Invalid demo result link.")
            let result: ResultBody = try await http.get("codex/\(accepted.jobID)/output")
            try require(result.status == "completed", "The remote output is incomplete.")
            let text: String
            var image: Data?
            if scenario.kind == .image || scenario.kind == .imageEdit {
                guard let first = result.images?.first, let data = Data(base64Encoded: first.base64),
                      let size = AgentImageAttachment.png(data).pixelSize, size == first.pixelSize else {
                    throw RemoteDemoFailure(message: "The returned PNG or dimensions are invalid.")
                }
                image = data
                text = "PNG \(size.width) × \(size.height)"
            } else {
                guard let output = result.outputText, !output.isEmpty else { throw LocalCloudDemoError.response }
                text = scenario.kind == .json
                    ? try JSONDecoder().decode(LocalCloudDemoProbe.Output.self, from: Data(output.utf8)).message : output
                if mode == .fixture { try require(text == "Local cloud bridge OK", "Unexpected fixture text/JSON result.") }
            }
            results.append(.init(id: accepted.jobID, kind: scenario.kind, push: scenario.push,
                text: text, image: image, submissions: scenario.retry ? 2 : 1))
            await progress("Completed \(scenario.kind.rawValue): \(text)")
        }
        let evidence: RemoteDemoQueue = try await http.get("demo/queue")
        let winning: CodexCompletionPush = scenarios.contains(where: { $0.push.resolved == .regular }) ? .regular : .silent
        try require(evidence.deliveries.count == 1 && evidence.deliveries.first?.completionPush == winning &&
            evidence.deliveries.first?.simulated == true && Set(evidence.deliveries[0].jobIds) == Set(results.map(\.id)),
            "The batch completion event did not preserve its preferences.")
        try require(evidence.submissions.filter(\.conflict).count == (checkConflict ? 1 : 0), "A conflict was retried.")
        for result in results {
            let attempts = evidence.submissions.filter { $0.jobId == result.id && !$0.conflict }
            try require(attempts.count == result.submissions && Set(attempts.map(\.envelopeSHA256)).count == 1 &&
                Set(attempts.map(\.clientRequestId)).count == 1 &&
                attempts.allSatisfy { $0.completionPush == result.push.resolved && $0.sha256 == $0.bodySHA256 } &&
                evidence.jobs.first(where: { $0.jobId == result.id })?.providerCalls == 1,
                "Submission retries changed the envelope or executed the provider more than once.")
        }
        await progress("Simulated device completion: \(winning.rawValue) · \(results.count) finished job(s) · one event")
        return .init(results: results, checks: [
            "\(results.count) remote job(s) completed through Swift → HTTP → TypeScript bridge → decoded result",
            "Middleware verified exact provider digests and identical retry envelopes; one provider call per job",
            "One simulated \(winning.rawValue) completion event after the device queue drained",
        ] + (checkConflict ? ["Changed preference returned 409 exactly once"] : []))
    }

    static func verify(baseURL: URL, progress: @escaping Progress = { _ in }) async throws -> RemoteDemoReport {
        var checks: [String] = []
        var results: [RemoteDemoResult] = []
        for kind in RemoteDemoKind.allCases {
            for push in RemoteDemoPush.allCases {
                let report = try await run(baseURL: baseURL, mode: .fixture, session: nil, model: "codexkit-fixture-model",
                    scenarios: [.init(kind: kind, push: push, retry: true)], prompt: "Confirm the remote demo.",
                    checkConflict: true, progress: progress)
                results += report.results
                checks.append("\(kind.rawValue) / \(push.rawValue): completed result, lost-reply retry, preserved digest, persisted selection, 409")
            }
        }
        let mixed = try await run(baseURL: baseURL, mode: .fixture, session: nil, model: "codexkit-fixture-model",
            scenarios: [.init(kind: .text, push: .defaultSilent, retry: true), .init(kind: .json, push: .regular),
                .init(kind: .image, push: .silent)], prompt: "Confirm the mixed batch.", progress: progress)
        results += mixed.results
        checks += mixed.checks
        let legacy = try await run(baseURL: baseURL, mode: .fixture, session: nil, model: "codexkit-fixture-model",
            scenarios: [.init(kind: .json, push: .defaultSilent, legacyMetadata: true)], prompt: "Legacy metadata.", progress: progress)
        results += legacy.results
        checks.append("Legacy submission and status metadata decode with silent fallback")
        return .init(results: results, checks: checks)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RemoteDemoFailure(message: message) }
    }

    private struct Health: Decodable { let mode: LocalCloudDemoMode }
    private struct Released: Decodable { let released: Bool }
    private struct ResultLink: Decodable { let jobId: String; let url: String }
    private struct ResultBody: Decodable {
        let status: String
        let outputText: String?
        let images: [Image]?
        struct Image: Decodable { let base64: String; let pixelSize: AgentImageDimensions }
    }

    private struct DemoHTTP {
        let baseURL: URL
        let device: String
        func get<Value: Decodable>(_ path: String, method: String = "GET") async throws -> Value {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = method
            request.setValue(device, forHTTPHeaderField: "x-demo-device")
            let limit = path.hasSuffix("/output") ? 64 * 1024 * 1024 : 8 * 1024 * 1024
            return try JSONDecoder().decode(Envelope<Value>.self,
                from: await LocalCloudHTTP.data(for: request, maximumBytes: limit)).data
        }
        struct Envelope<Value: Decodable>: Decodable { let data: Value }
    }
}
#endif
