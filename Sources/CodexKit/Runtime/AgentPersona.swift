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
    static func compile(
        baseInstructions: String?,
        threadPersonaStack: AgentPersonaStack?,
        threadSkills: [AgentSkill],
        turnPersonaOverride: AgentPersonaStack?,
        turnSkills: [AgentSkill]
    ) -> String {
        var sections: [String] = []

        let trimmedBase = baseInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedBase.isEmpty {
            sections.append(trimmedBase)
        }

        if let threadPersonaStack,
           let compiledThreadLayers = compile(
               title: "Thread Persona Layers",
               stack: threadPersonaStack
           ) {
            sections.append(compiledThreadLayers)
        }

        if let compiledThreadSkills = compile(
            title: "Thread Skills",
            skills: threadSkills
        ) {
            sections.append(compiledThreadSkills)
        }

        if let turnPersonaOverride,
           let compiledOverrideLayers = compile(
               title: "Turn Persona Override",
               stack: turnPersonaOverride
           ) {
            sections.append(compiledOverrideLayers)
        }

        if let compiledTurnSkills = compile(
            title: "Turn Skill Override",
            skills: turnSkills
        ) {
            sections.append(compiledTurnSkills)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func compile(
        title: String,
        stack: AgentPersonaStack
    ) -> String? {
        let renderedLayers = stack.layers.compactMap { layer -> String? in
            let trimmedInstructions = layer.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInstructions.isEmpty else {
                return nil
            }

            return """
            [\(layer.name)]
            \(trimmedInstructions)
            """
        }

        guard !renderedLayers.isEmpty else {
            return nil
        }

        return """
        \(title):
        \(renderedLayers.joined(separator: "\n\n"))
        """
    }

    private static func compile(
        title: String,
        skills: [AgentSkill]
    ) -> String? {
        let renderedSkills = skills.compactMap { skill -> String? in
            let trimmedInstructions = skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let policyLines = compilePolicyLines(skill.executionPolicy)
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

            return """
            [\(skill.id): \(skill.name)]
            \(sections.joined(separator: "\n\n"))
            """
        }

        guard !renderedSkills.isEmpty else {
            return nil
        }

        return """
        \(title):
        \(renderedSkills.joined(separator: "\n\n"))
        """
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
