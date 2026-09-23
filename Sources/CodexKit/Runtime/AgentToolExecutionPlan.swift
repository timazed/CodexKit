import Foundation

struct ToolAdmission: Sendable {
    let invocation: ToolInvocation
    let failure: ToolFailure?
    let advancesSequence: Bool
}

struct ToolExecutionPlan: Sendable {
    let waves: [[ToolAdmission]]
}

extension AgentRuntime {
    typealias CompiledSkillToolPolicy = AgentSkillExecutionPolicy

    /// Turn-local state. Only admission reserves budgets; executor tasks never
    /// validate policy or race to claim a remaining slot.
    actor TurnSkillPolicyTracker {
        let policy: CompiledSkillToolPolicy
        private var calls = 0
        private var callsByName: [String: Int] = [:]
        private var rounds = 0
        private var roundIDs: Set<String> = []
        private var invocationIDs: Set<String> = []
        private var usedToolNames: Set<String> = []
        private var nextSequenceIndex = 0

        init(policy: CompiledSkillToolPolicy) { self.policy = policy }

        func plan(
            _ round: AgentToolRound, definitions: [String: ToolDefinition], maximumConcurrency: Int
        ) throws -> ToolExecutionPlan {
            guard !round.id.isEmpty, !round.calls.isEmpty else {
                throw AgentRuntimeError(code: .invalidToolRound, message: "A tool round must have an ID and at least one call.")
            }
            let ids = Set(round.calls.map(\.id))
            guard !roundIDs.contains(round.id), ids.count == round.calls.count,
                  invocationIDs.isDisjoint(with: ids) else {
                throw AgentRuntimeError(code: .duplicateToolCall, message: "A tool round or invocation was announced more than once.")
            }
            roundIDs.insert(round.id)
            invocationIDs.formUnion(ids)
            let roundExceeded = policy.maxToolRounds.map { rounds >= $0 } ?? false
            if !roundExceeded { rounds += 1 }
            let limit = min(maximumConcurrency, policy.maximumParallelToolCalls ?? maximumConcurrency)
            var sequenceIndex = nextSequenceIndex
            var waves: [[ToolAdmission]] = []
            var wave: [ToolAdmission] = []
            for invocation in round.calls {
                let name = invocation.toolName
                let expected = policy.toolSequence.flatMap { sequenceIndex < $0.count ? $0[sequenceIndex] : nil }
                let failure = validationFailure(name: name, expected: expected, roundExceeded: roundExceeded)
                let advancesSequence = failure == nil && expected != nil
                if failure == nil {
                    calls += 1
                    callsByName[name, default: 0] += 1
                    if advancesSequence { sequenceIndex += 1 }
                }
                let admission = ToolAdmission(invocation: invocation, failure: failure, advancesSequence: advancesSequence)
                let definition = definitions[name]
                let concurrent = !advancesSequence && definition?.supportsParallelExecution == true &&
                    definition?.approvalPolicy == .automatic
                if !concurrent {
                    if !wave.isEmpty { waves.append(wave); wave.removeAll() }
                    waves.append([admission])
                } else {
                    wave.append(admission)
                    if wave.count == limit { waves.append(wave); wave.removeAll() }
                }
            }
            if !wave.isEmpty { waves.append(wave) }
            return ToolExecutionPlan(waves: waves)
        }

        private func validationFailure(name: String, expected: String?, roundExceeded: Bool) -> ToolFailure? {
            if roundExceeded {
                return .init(code: "tool_round_budget_exceeded", message: "The active skill policy's host-tool round budget is exhausted.")
            }
            if let maximum = policy.maxToolCalls, calls >= maximum {
                return .init(code: "tool_budget_exceeded", message: AgentRuntimeError.skillToolCallLimitExceeded(maximum).message)
            }
            if let maximum = policy.maxToolCallsByName?[name], callsByName[name, default: 0] >= maximum {
                return .init(code: "tool_budget_exceeded", message: "The active skill policy allows at most \(maximum) call(s) to \(name) per turn.")
            }
            if let allowed = policy.allowedToolNames, !allowed.contains(name) {
                return .init(code: "tool_not_allowed", message: AgentRuntimeError.skillToolNotAllowed(name).message)
            }
            if let expected, name != expected {
                return .init(code: "tool_sequence_violation", message: AgentRuntimeError.skillToolSequenceViolation(expected: expected, actual: name).message)
            }
            return nil
        }

        /// Preserve accepted-call semantics: failures, denials and unknown-tool
        /// results count, but policy rejections and interrupted calls do not.
        func recordSettled(_ admission: ToolAdmission) {
            guard admission.failure == nil else { return }
            usedToolNames.insert(admission.invocation.toolName)
            if admission.advancesSequence { nextSequenceIndex += 1 }
        }

        func completionError() -> AgentRuntimeError? {
            var missing = Set(policy.requiredToolNames).subtracting(usedToolNames)
            if let sequence = policy.toolSequence, nextSequenceIndex < sequence.count {
                missing.formUnion(sequence[nextSequenceIndex...])
            }
            return missing.isEmpty ? nil : .skillRequiredToolsMissing(Array(missing).sorted())
        }
    }
}
