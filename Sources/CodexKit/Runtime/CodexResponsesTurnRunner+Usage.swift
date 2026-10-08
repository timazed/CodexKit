import Foundation

extension CodexResponsesTurnRunner {
    func recordUsage(_ usage: AgentUsage, outcome: AgentUsageObservation.Outcome,
                     responseID: String?, attemptID: String, state: inout TurnRunState) async {
        let recovery = AgentStructuredRecoveryContext.current
        let observation = AgentUsageObservation(
            id: responseID.map { "response:" + $0 } ?? "attempt:" + attemptID,
            threadID: threadID, turnID: turnID, requestID: state.usageRequestID,
            passNumber: state.passNumber, attemptID: attemptID, responseID: responseID,
            operationID: recovery?.operationID, rootOperationID: recovery?.rootOperationID,
            model: threadConfiguration.model, reasoningEffort: threadConfiguration.reasoningEffort,
            outcome: outcome, usage: usage)
        if state.usageAccumulator.insert(observation) {
            logger.info(.network, "Provider usage observed.", metadata: observation.logMetadata)
            await recovery?.recordUsage(observation)
        }
    }
}
