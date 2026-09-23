import Foundation

extension AgentRuntime {
    // MARK: - Skills

    public func skills() -> [AgentSkill] {
        skillsByID.values.sorted { $0.id < $1.id }
    }

    public func skill(for skillID: String) -> AgentSkill? {
        skillsByID[skillID]
    }

    public func registerSkill(_ skill: AgentSkill) throws {
        guard AgentSkill.isValidID(skill.id) else {
            throw AgentRuntimeError.invalidSkillID(skill.id)
        }
        try Self.validateSkillExecutionPolicy(skill)
        guard skillsByID[skill.id] == nil else {
            throw AgentRuntimeError.duplicateSkill(skill.id)
        }

        skillsByID[skill.id] = skill
    }

    public func replaceSkill(_ skill: AgentSkill) throws {
        guard AgentSkill.isValidID(skill.id) else {
            throw AgentRuntimeError.invalidSkillID(skill.id)
        }
        try Self.validateSkillExecutionPolicy(skill)

        skillsByID[skill.id] = skill
    }

    @discardableResult
    public func registerSkill(
        from source: AgentDefinitionSource,
        id: String? = nil,
        name: String? = nil
    ) async throws -> AgentSkill {
        let skill = try await definitionSourceLoader.loadSkill(
            from: source,
            id: id,
            name: name
        )
        try registerSkill(skill)
        return skill
    }

    @discardableResult
    public func replaceSkill(
        from source: AgentDefinitionSource,
        id: String? = nil,
        name: String? = nil
    ) async throws -> AgentSkill {
        let skill = try await definitionSourceLoader.loadSkill(
            from: source,
            id: id,
            name: name
        )
        try replaceSkill(skill)
        return skill
    }

    public func skillIDs(for threadID: String) throws -> [String] {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return thread.skillIDs
    }

    public func setSkillIDs(
        _ skillIDs: [String],
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        try assertSkillsExist(skillIDs)

        state.threads[index].skillIDs = skillIDs
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        try await persistState()
    }

    // MARK: - Skill Policy

    func resolveTurnSkills(
        thread: AgentThread,
        message: Request
    ) throws -> ResolvedTurnSkills {
        let selectedSkillIDs = switch message.skillSelection {
        case .none:
            thread.skillIDs
        case let .replace(skillIDs):
            skillIDs
        case let .append(skillIDs):
            thread.skillIDs + skillIDs
        }
        try assertSkillsExist(selectedSkillIDs)

        let threadSkills: [AgentSkill] = switch message.skillSelection {
        case .none, .append:
            resolveSkills(for: thread.skillIDs)
        case .replace:
            []
        }
        let turnSkills: [AgentSkill] = switch message.skillSelection {
        case .none:
            []
        case let .replace(skillIDs), let .append(skillIDs):
            resolveSkills(for: skillIDs)
        }
        let allSkills = threadSkills + turnSkills

        return ResolvedTurnSkills(
            threadSkills: threadSkills,
            turnSkills: turnSkills,
            compiledToolPolicy: try compileToolPolicy(from: allSkills)
        )
    }

    private func compileToolPolicy(from skills: [AgentSkill]) throws -> CompiledSkillToolPolicy {
        var policy = AgentSkillExecutionPolicy()
        for skill in skills {
            guard let incoming = skill.executionPolicy else { continue }
            if let allowed = incoming.allowedToolNames {
                policy.allowedToolNames = policy.allowedToolNames.map {
                    Array(Set($0).intersection(allowed)).sorted()
                } ?? Array(Set(allowed)).sorted()
            }
            policy.requiredToolNames = Array(Set(policy.requiredToolNames + incoming.requiredToolNames)).sorted()
            if let sequence = incoming.toolSequence, !sequence.isEmpty {
                if let existing = policy.toolSequence {
                    guard existing.starts(with: sequence) || sequence.starts(with: existing) else {
                        throw AgentRuntimeError(code: .conflictingSkillToolSequences,
                            message: "Active skills require incompatible exact tool prefixes.")
                    }
                    if sequence.count > existing.count { policy.toolSequence = sequence }
                } else { policy.toolSequence = sequence }
            }
            policy.maxToolCalls = Self.minimumLimit(policy.maxToolCalls, incoming.maxToolCalls)
            policy.maxToolRounds = Self.minimumLimit(policy.maxToolRounds, incoming.maxToolRounds)
            policy.maximumParallelToolCalls = Self.minimumLimit(policy.maximumParallelToolCalls, incoming.maximumParallelToolCalls)
            if let search = incoming.webSearch {
                policy.webSearch = try policy.webSearch.map { try $0.narrowed(by: search) } ?? search.normalized()
            }
            if let limits = incoming.maxToolCallsByName {
                var merged = policy.maxToolCallsByName ?? [:]
                for (name, limit) in limits { merged[name] = min(merged[name] ?? limit, limit) }
                policy.maxToolCallsByName = merged
            }
        }
        return policy
    }

    static func minimumLimit(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private func resolveSkills(for skillIDs: [String]) -> [AgentSkill] {
        skillIDs.compactMap { skillsByID[$0] }
    }

    func assertSkillsExist(_ skillIDs: [String]) throws {
        let missing = Array(Set(skillIDs.filter { skillsByID[$0] == nil })).sorted()
        guard missing.isEmpty else {
            throw AgentRuntimeError.skillsNotFound(missing)
        }
    }

    static func validatedSkills(from skills: [AgentSkill]) throws -> [String: AgentSkill] {
        var dictionary: [String: AgentSkill] = [:]
        for skill in skills {
            guard AgentSkill.isValidID(skill.id) else {
                throw AgentRuntimeError.invalidSkillID(skill.id)
            }
            try validateSkillExecutionPolicy(skill)
            guard dictionary[skill.id] == nil else {
                throw AgentRuntimeError.duplicateSkill(skill.id)
            }
            dictionary[skill.id] = skill
        }
        return dictionary
    }

    static func validateSkillExecutionPolicy(_ skill: AgentSkill) throws {
        guard let executionPolicy = skill.executionPolicy else {
            return
        }

        if let maxToolCalls = executionPolicy.maxToolCalls,
           maxToolCalls < 0 {
            throw AgentRuntimeError.invalidSkillMaxToolCalls(skillID: skill.id)
        }

        guard executionPolicy.hasValidLimits else {
            throw AgentRuntimeError(code: .invalidSkillDefinition,
                message: "Skill budgets must be nonnegative and maximumParallelToolCalls must be at least one.")
        }
        _ = try executionPolicy.webSearch?.normalized()
        let policyToolNames = executionPolicy.policyToolNames

        for toolName in policyToolNames {
            guard ToolDefinition.isValidName(toolName) else {
                throw AgentRuntimeError.invalidSkillToolName(
                    skillID: skill.id,
                    toolName: toolName
                )
            }
        }
    }
}
