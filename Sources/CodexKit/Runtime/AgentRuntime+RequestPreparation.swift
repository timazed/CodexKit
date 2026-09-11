import Foundation

extension AgentRuntime {
    func resolveRequestConfiguration(_ request: Request, thread: AgentThread,
        responseFormat: AgentStructuredOutputFormat?, session: ChatGPTSession) async throws -> (Request, AgentThread) {
        var request = request
        var thread = thread
        if let preparing = backend as? any AgentBackendRequestPreparing {
            let selection = try await preparing.prepareModelSelection(for: request, in: thread,
                responseFormat: responseFormat, session: session)
            try Task.checkCancellation()
            try await validateActiveAuthentication(session)
            if let fixed = request.modelOverride, fixed != selection.configuration {
                throw AgentModelSelectionError.invalidConfiguration
            }
            request.resolvedModelSelection = selection
            thread.configuration = selection.configuration
        } else if let override = request.modelOverride {
            thread.configuration = override
        }
        return (request, thread)
    }
}
