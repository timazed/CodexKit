import CryptoKit
import Foundation

extension AgentRuntime {
    struct ResolvedAgentInstructions: Sendable {
        let text: String
        let contextCompactionText: String
        let memory: ResolvedMemoryInstructionsPreview?
        let threadConfiguration: AgentThreadConfiguration?

        var preview: ResolvedAgentInstructionsPreview {
            ResolvedAgentInstructionsPreview(
                instructions: text,
                memory: memory
            )
        }
    }

    func resolveInstructions(
        thread: AgentThread,
        message: Request,
        resolvedTurnSkills: ResolvedTurnSkills
    ) async throws -> ResolvedAgentInstructions {
        let baseInstructions: String?
        if let configuredBaseInstructions {
            baseInstructions = configuredBaseInstructions
        } else {
            baseInstructions = await backend.baseInstructions
        }
        try Task.checkCancellation()

        let resolvedMemory = try await resolveMemoryInstructions(
            thread: thread,
            message: message,
            resolvedTurnSkills: resolvedTurnSkills
        )
        let compiled = AgentInstructionCompiler.compile(
            baseInstructions: baseInstructions,
            threadPersonaStack: thread.personaStack,
            threadSkills: resolvedTurnSkills.threadSkills,
            turnPersonaOverride: message.personaOverride,
            turnSkills: resolvedTurnSkills.turnSkills,
            memoryInstructions: resolvedMemory?.renderedInstructions,
            memoryPlacement: resolvedMemory?.placement ?? .afterSkills
        )
        let compactionCompiled = AgentInstructionCompiler.compile(
            baseInstructions: baseInstructions,
            threadPersonaStack: thread.personaStack,
            threadSkills: resolvedTurnSkills.threadSkills,
            turnPersonaOverride: message.personaOverride,
            turnSkills: resolvedTurnSkills.turnSkills,
            memoryInstructions: resolvedMemory?.renderedInstructions,
            memoryPlacement: resolvedMemory?.placement ?? .afterSkills,
            includesSkillExecutionPolicies: false
        )
        try Task.checkCancellation()

        return ResolvedAgentInstructions(
            text: compiled,
            contextCompactionText: compactionCompiled,
            memory: resolvedMemory,
            threadConfiguration: thread.configuration
        )
    }

    private func resolveMemoryInstructions(
        thread: AgentThread,
        message: Request,
        resolvedTurnSkills: ResolvedTurnSkills
    ) async throws -> ResolvedMemoryInstructionsPreview? {
        guard let memoryConfiguration,
              let queryResolution = try await resolvedMemoryQuery(
                  thread: thread,
                  message: message
              )
        else {
            return nil
        }

        let budget = resolvedMemoryBudget(
            thread: thread,
            message: message,
            fallback: memoryConfiguration.defaultReadBudget
        )
        let rendered = memoryConfiguration.promptRenderer.renderWithMetadata(
            result: queryResolution.result,
            budget: budget
        )
        try Task.checkCancellation()
        let instructions = rendered.instructions.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !instructions.isEmpty else {
            return nil
        }
        guard instructions.count <= max(0, budget.maxCharacters) else {
            logger.warning(
                .memory,
                "Skipped memory because its renderer exceeded the configured character budget.",
                metadata: [
                    "rendered_characters": "\(instructions.count)",
                    "maximum_characters": "\(max(0, budget.maxCharacters))",
                ]
            )
            return nil
        }

        let preview = ResolvedMemoryInstructionsPreview(
            query: queryResolution.query,
            result: queryResolution.result,
            renderedInstructions: instructions,
            includedRecordIDs: normalizedIncludedRecordIDs(
                rendered.includedRecordIDs,
                result: queryResolution.result
            ),
            placement: message.memorySelection?.instructionPlacement
                ?? thread.memoryContext?.instructionPlacement
                ?? memoryConfiguration.instructionPlacement
        )
        guard memoryAttributionIsPersistable(
            preview,
            thread: thread,
            resolvedTurnSkills: resolvedTurnSkills,
            memoryConfiguration: memoryConfiguration
        ) else {
            return nil
        }
        return preview
    }

    private func memoryAttributionIsPersistable(
        _ memory: ResolvedMemoryInstructionsPreview,
        thread: AgentThread,
        resolvedTurnSkills: ResolvedTurnSkills,
        memoryConfiguration: AgentMemoryConfiguration
    ) -> Bool {
        let snapshot = MemoryApplicationSnapshot(
            threadID: thread.id,
            turnID: AgentStoreLimits.maximumEncodedIdentifierPlaceholder,
            clientRequestID: AgentStoreLimits.maximumEncodedIdentifierPlaceholder,
            model: thread.configuration?.model,
            reasoningEffort: thread.configuration?.reasoningEffort,
            activeSkillIDs: activeSkillIDs(resolvedTurnSkills),
            promptRendererIdentifier: promptRendererIdentifier(memoryConfiguration),
            compiledInstructionsSHA256: String(repeating: "0", count: 64),
            query: memory.query,
            result: memory.result,
            renderedInstructions: memory.renderedInstructions,
            includedRecordIDs: memory.includedRecordIDs,
            placement: memory.placement
        )

        do {
            try AgentStoredPayloadValidator.validateMemoryApplication(snapshot)
            return true
        } catch {
            logger.warning(
                .memory,
                "Skipped memory because its attribution could not be persisted safely.",
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func normalizedIncludedRecordIDs(
        _ recordIDs: [String],
        result: MemoryQueryResult
    ) -> [String] {
        guard recordIDs.count <= MemoryStoreLimits.maximumQueryResultCount else {
            logger.warning(
                .memory,
                "Ignored memory renderer attribution because it exceeded the record-ID limit.",
                metadata: [
                    "declared_record_ids": "\(recordIDs.count)",
                    "maximum_record_ids": "\(MemoryStoreLimits.maximumQueryResultCount)",
                ]
            )
            return []
        }
        let selectedRecordIDs = Set(result.matches.map(\.record.id))
        var seen = Set<String>()
        var normalized: [String] = []
        var rejectedRecordIDs: [String] = []
        var rejectedRecordIDCount = 0
        for recordID in recordIDs {
            guard !recordID.isEmpty,
                  recordID.utf8.count <= MemoryStoreLimits.maximumIdentifierByteCount,
                  selectedRecordIDs.contains(recordID) else {
                rejectedRecordIDCount += 1
                if rejectedRecordIDs.count < 8 {
                    rejectedRecordIDs.append(
                        String(recordID.prefix(64))
                    )
                }
                continue
            }
            if seen.insert(recordID).inserted {
                normalized.append(recordID)
            }
        }
        if rejectedRecordIDCount > 0 {
            logger.warning(
                .memory,
                "Memory renderer declared records outside the selected query result.",
                metadata: [
                    "rejected_record_id_count": "\(rejectedRecordIDCount)",
                    "rejected_record_id_sample": rejectedRecordIDs.sorted().joined(separator: ","),
                ]
            )
        }
        return normalized
    }

    func makeMemoryApplicationSnapshot(
        resolvedInstructions: ResolvedAgentInstructions,
        threadID: String,
        turnID: String,
        clientRequestID: String?,
        resolvedTurnSkills: ResolvedTurnSkills
    ) -> MemoryApplicationSnapshot? {
        guard let memory = resolvedInstructions.memory,
              let memoryConfiguration
        else { return nil }

        return MemoryApplicationSnapshot(
            threadID: threadID,
            turnID: turnID,
            clientRequestID: clientRequestID,
            model: resolvedInstructions.threadConfiguration?.model,
            reasoningEffort: resolvedInstructions.threadConfiguration?.reasoningEffort,
            activeSkillIDs: activeSkillIDs(resolvedTurnSkills),
            promptRendererIdentifier: promptRendererIdentifier(memoryConfiguration),
            compiledInstructionsSHA256: sha256(resolvedInstructions.text),
            query: memory.query,
            result: memory.result,
            renderedInstructions: memory.renderedInstructions,
            includedRecordIDs: memory.includedRecordIDs,
            placement: memory.placement
        )
    }

    func makeMemoryCompactionApplicationSnapshot(
        resolvedInstructions: ResolvedAgentInstructions,
        threadID: String,
        generation: Int,
        reason: AgentContextCompactionReason,
        clientRequestID: String?,
        resolvedTurnSkills: ResolvedTurnSkills
    ) -> MemoryCompactionApplicationSnapshot? {
        guard let memory = resolvedInstructions.memory,
              let memoryConfiguration
        else { return nil }

        return MemoryCompactionApplicationSnapshot(
            threadID: threadID,
            generation: generation,
            reason: reason,
            clientRequestID: clientRequestID,
            model: resolvedInstructions.threadConfiguration?.model,
            reasoningEffort: resolvedInstructions.threadConfiguration?.reasoningEffort,
            activeSkillIDs: activeSkillIDs(resolvedTurnSkills),
            promptRendererIdentifier: promptRendererIdentifier(memoryConfiguration),
            compiledInstructionsSHA256: sha256(resolvedInstructions.contextCompactionText),
            query: memory.query,
            result: memory.result,
            renderedInstructions: memory.renderedInstructions,
            includedRecordIDs: memory.includedRecordIDs,
            placement: memory.placement
        )
    }

    func notifyMemoryApplication(_ application: MemoryApplicationSnapshot?) {
        guard let application,
              let observer = memoryConfiguration?.observer
        else { return }

        Task {
            await observer.handle(application: application)
        }
    }

    func notifyMemoryCompactionApplication(
        _ application: MemoryCompactionApplicationSnapshot?
    ) {
        guard let application,
              let observer = memoryConfiguration?.observer
        else { return }

        Task {
            await observer.handle(compactionApplication: application)
        }
    }

    private func activeSkillIDs(_ skills: ResolvedTurnSkills) -> [String] {
        (skills.threadSkills + skills.turnSkills).map(\.id)
    }

    private func promptRendererIdentifier(
        _ configuration: AgentMemoryConfiguration
    ) -> String {
        String(reflecting: type(of: configuration.promptRenderer))
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func resolvedInstructionsPreview(
        for threadID: String,
        request: Request
    ) async throws -> String {
        try await resolvedInstructionsPreviewDetails(
            for: threadID,
            request: request
        ).instructions
    }

    public func resolvedInstructionsPreviewDetails(
        for threadID: String,
        request: Request
    ) async throws -> ResolvedAgentInstructionsPreview {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )
        return try await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        ).preview
    }
}
