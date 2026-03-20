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
        turnPersonaOverride: AgentPersonaStack?
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

        if let turnPersonaOverride,
           let compiledOverrideLayers = compile(
               title: "Turn Persona Override",
               stack: turnPersonaOverride
           ) {
            sections.append(compiledOverrideLayers)
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
}
