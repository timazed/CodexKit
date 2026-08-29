import Foundation

public struct AgentPersonaLayer: Codable, Hashable, Sendable {
    public var name: String
    public var instructions: String

    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }
}

public struct AgentPersonaStack: Codable, Hashable, Sendable {
    public var layers: [AgentPersonaLayer]

    public init(layers: [AgentPersonaLayer]) {
        self.layers = layers
    }

    public var isEmpty: Bool {
        layers.isEmpty
    }
}

enum AgentInstructionCompiler {
    private struct Section {
        enum Kind {
            case base
            case persona
            case skill
            case memory
        }

        let kind: Kind
        let text: String
    }

    static func compile(
        baseInstructions: String?,
        threadPersonaStack: AgentPersonaStack?,
        threadSkills: [AgentSkill],
        turnPersonaOverride: AgentPersonaStack?,
        turnSkills: [AgentSkill],
        memoryInstructions: String? = nil,
        memoryPlacement: MemoryInstructionPlacement = .afterSkills,
        includesSkillExecutionPolicies: Bool = true
    ) -> String {
        var sections: [Section] = []
        let usesPersonaOverride = turnPersonaOverride?.isEmpty == false
        let usesThreadPersona = threadPersonaStack?.isEmpty == false

        let trimmedBase = baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !usesPersonaOverride, !usesThreadPersona, !trimmedBase.isEmpty {
            sections.append(Section(kind: .base, text: trimmedBase))
        }

        if !usesPersonaOverride,
           let threadPersonaStack,
           let compiledThreadLayers = compile(stack: threadPersonaStack) {
            sections.append(Section(kind: .persona, text: compiledThreadLayers))
        }

        if let compiledThreadSkills = compile(
            skills: threadSkills,
            includesExecutionPolicies: includesSkillExecutionPolicies
        ) {
            sections.append(Section(kind: .skill, text: compiledThreadSkills))
        }

        if let turnPersonaOverride,
           let compiledOverrideLayers = compile(stack: turnPersonaOverride) {
            sections.append(Section(kind: .persona, text: compiledOverrideLayers))
        }

        if let compiledTurnSkills = compile(
            skills: turnSkills,
            includesExecutionPolicies: includesSkillExecutionPolicies
        ) {
            sections.append(Section(kind: .skill, text: compiledTurnSkills))
        }

        let trimmedMemory = memoryInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedMemory.isEmpty {
            let insertionIndex = switch memoryPlacement {
            case .beforePersonas:
                sections.firstIndex(where: { $0.kind != .base }) ?? sections.endIndex
            case .beforeSkills:
                sections.firstIndex(where: { $0.kind == .skill }) ?? sections.endIndex
            case .afterSkills:
                sections.endIndex
            }
            sections.insert(
                Section(kind: .memory, text: trimmedMemory),
                at: insertionIndex
            )
        }

        return sections.map(\.text).joined(separator: "\n\n")
    }

    private static func compile(stack: AgentPersonaStack) -> String? {
        let renderedLayers = stack.layers.compactMap { layer -> String? in
            let trimmedInstructions = layer.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInstructions.isEmpty else {
                return nil
            }

            return trimmedInstructions
        }

        guard !renderedLayers.isEmpty else {
            return nil
        }

        return renderedLayers.joined(separator: "\n\n")
    }

    private static func compile(
        skills: [AgentSkill],
        includesExecutionPolicies: Bool
    ) -> String? {
        let renderedSkills = skills.compactMap { skill -> String? in
            let trimmedInstructions = skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let policyLines = includesExecutionPolicies
                ? compilePolicyLines(skill.executionPolicy)
                : []
            guard !trimmedInstructions.isEmpty || !policyLines.isEmpty else {
                return nil
            }

            var sections: [String] = []
            if !trimmedInstructions.isEmpty {
                sections.append(trimmedInstructions)
            }
            if !policyLines.isEmpty {
                sections.append(
                    """
                    Execution Policy:
                    \(policyLines.joined(separator: "\n"))
                    """
                )
            }

            return sections.joined(separator: "\n\n")
        }

        guard !renderedSkills.isEmpty else {
            return nil
        }

        return renderedSkills.joined(separator: "\n\n")
    }

    private static func compilePolicyLines(
        _ policy: AgentSkillExecutionPolicy?
    ) -> [String] {
        guard let policy else {
            return []
        }

        var lines: [String] = []

        if let allowedToolNames = policy.allowedToolNames,
           !allowedToolNames.isEmpty {
            lines.append("- allowed tools: \(allowedToolNames.joined(separator: ", "))")
        }

        if !policy.requiredToolNames.isEmpty {
            lines.append("- required tools this turn: \(policy.requiredToolNames.joined(separator: ", "))")
        }

        if let toolSequence = policy.toolSequence,
           !toolSequence.isEmpty {
            lines.append("- required tool sequence: \(toolSequence.joined(separator: " -> "))")
        }

        if let maxToolCalls = policy.maxToolCalls {
            lines.append("- max tool calls this turn: \(maxToolCalls)")
        }

        return lines
    }
}
