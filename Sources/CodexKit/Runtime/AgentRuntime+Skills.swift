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
        message: UserMessageRequest
    ) throws -> ResolvedTurnSkills {
        if let skillOverrideIDs = message.skillOverrideIDs {
            try assertSkillsExist(skillOverrideIDs)
        }

        let threadSkills = resolveSkills(for: thread.skillIDs)
        let turnSkills = resolveSkills(for: message.skillOverrideIDs ?? [])
        let allSkills = threadSkills + turnSkills

        return ResolvedTurnSkills(
            threadSkills: threadSkills,
            turnSkills: turnSkills,
            compiledToolPolicy: compileToolPolicy(from: allSkills)
        )
    }

    private func compileToolPolicy(from skills: [AgentSkill]) -> CompiledSkillToolPolicy {
        var allowedToolNames: Set<String>?
        var requiredToolNames: Set<String> = []
        var toolSequence: [String]?
        var maxToolCalls: Int?

        for skill in skills {
            guard let executionPolicy = skill.executionPolicy else {
                continue
            }

            if let allowed = executionPolicy.allowedToolNames,
               !allowed.isEmpty {
                let allowedSet = Set(allowed)
                if let existingAllowed = allowedToolNames {
                    allowedToolNames = existingAllowed.intersection(allowedSet)
                } else {
                    allowedToolNames = allowedSet
                }
            }

            if !executionPolicy.requiredToolNames.isEmpty {
                requiredToolNames.formUnion(executionPolicy.requiredToolNames)
            }

            if let sequence = executionPolicy.toolSequence,
               !sequence.isEmpty {
                toolSequence = sequence
            }

            if let maxCalls = executionPolicy.maxToolCalls {
                if let existingMaxCalls = maxToolCalls {
                    maxToolCalls = min(existingMaxCalls, maxCalls)
                } else {
                    maxToolCalls = maxCalls
                }
            }
        }

        return CompiledSkillToolPolicy(
            allowedToolNames: allowedToolNames,
            requiredToolNames: requiredToolNames,
            toolSequence: toolSequence,
            maxToolCalls: maxToolCalls
        )
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

        let policyToolNames: [String] =
            (executionPolicy.allowedToolNames ?? []) +
            executionPolicy.requiredToolNames +
            (executionPolicy.toolSequence ?? [])

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
