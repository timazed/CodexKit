import CodexKit
import Darwin
import Foundation
import RecoveryIntegrationSupport

@main struct RecoveryIntegrationFixture {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw FixtureHostStore.HostError.inapplicable }
        let mode = arguments[1]
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let store = AgentStructuredRecoveryStore(directory: directory.appendingPathComponent("receipts"))
        let host = try FixtureHostStore(directory: directory)
        FixtureTransport.configure(mode == "seed" ? ["news": [.complete("saved")]] : [:],
            log: directory.appendingPathComponent("requests.log"))
        let runtime = try fixtureRuntime(selector: mode == "seed" ? PurposeSelector() : RejectingSelector())
        if mode == "seed" {
            let thread = try await runtime.createThread()
            var request = Request(text: "news", executionMode: .ephemeral)
            request.selectionPurpose = "news"
            let handle = try await runtime.prepareStructuredRecovery(request, in: thread.id,
                response: FixtureOutput.self, store: store, hostJobID: "news", inputRevision: "1")
            try await host.register("news", handle: handle)
            _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
            _exit(73) // Intentionally terminate after SDK receipt persistence, before host commit.
        }
        guard let job = await host.job("news") else { throw FixtureHostStore.HostError.inapplicable }
        let status = try await runtime.structuredRecoveryStatus(job.handle, store: store)
        if status.state != .acknowledged {
            let receipt = try await runtime.structuredRecoveryReceipt(job.handle, store: store)
            guard receipt.usage?.inputTokens == 100, receipt.usage?.codexRolloutBudgetUnits == 2.5,
                  receipt.usage?.availability(of: .reasoningOutputTokens) == .complete,
                  receipt.usageObservations.count == 1,
                  receipt.usageObservations.first?.id == "response:saved-response",
                  receipt.usageObservations.first?.isReused == true,
                  status.usage == receipt.usage else { throw FixtureHostStore.HostError.inapplicable }
            let output = try await runtime.sendRecovering(job.handle, response: FixtureOutput.self, store: store) { _ in
                throw FixtureHostStore.HostError.inapplicable // No generation is authorized after the first process.
            }
            try await host.commit(output, jobID: "news")
            if mode == "commit-crash" { _exit(74) }
        }
        try await runtime.acknowledgeStructuredRecovery(job.handle, store: store)
        guard let committed = await host.job("news"), committed.commitCount == 1,
              FixtureTransport.generationCount == 0 else { throw FixtureHostStore.HostError.inapplicable }
        print("Recovered and acknowledged one host commit with zero additional generation requests.")
    }
}
