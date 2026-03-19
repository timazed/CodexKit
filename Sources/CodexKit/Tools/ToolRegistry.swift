import Foundation

public enum ToolRegistryError: Error, LocalizedError, Sendable {
    case duplicateTool(String)
    case invalidToolName(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateTool(name):
            return "A tool named \(name) is already registered."
        case let .invalidToolName(name):
            return "Invalid tool name \(name). Tool names must match ^[a-zA-Z0-9_-]+$."
        }
    }
}

actor ToolRegistry {
    private struct Entry: Sendable {
        let definition: ToolDefinition
        let executor: AnyToolExecutor
    }

    private var entries: [String: Entry] = [:]

    init(initialTools: [AgentRuntime.ToolRegistration] = []) throws {
        for tool in initialTools {
            guard ToolDefinition.isValidName(tool.definition.name) else {
                throw ToolRegistryError.invalidToolName(tool.definition.name)
            }

            guard entries[tool.definition.name] == nil else {
                throw ToolRegistryError.duplicateTool(tool.definition.name)
            }

            entries[tool.definition.name] = Entry(
                definition: tool.definition,
                executor: tool.executor
            )
        }
    }

    func register(
        _ definition: ToolDefinition,
        executor: AnyToolExecutor
    ) throws {
        guard ToolDefinition.isValidName(definition.name) else {
            throw ToolRegistryError.invalidToolName(definition.name)
        }

        guard entries[definition.name] == nil else {
            throw ToolRegistryError.duplicateTool(definition.name)
        }

        entries[definition.name] = Entry(definition: definition, executor: executor)
    }

    func replace(
        _ definition: ToolDefinition,
        executor: AnyToolExecutor
    ) throws {
        guard ToolDefinition.isValidName(definition.name) else {
            throw ToolRegistryError.invalidToolName(definition.name)
        }

        entries[definition.name] = Entry(definition: definition, executor: executor)
    }

    func definition(named name: String) -> ToolDefinition? {
        entries[name]?.definition
    }

    func allDefinitions() -> [ToolDefinition] {
        entries.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    func execute(
        _ invocation: ToolInvocation,
        session: ChatGPTSession?
    ) async -> ToolResultEnvelope {
        guard let entry = entries[invocation.toolName] else {
            return .failure(
                invocation: invocation,
                message: "No tool named \(invocation.toolName) is registered."
            )
        }

        do {
            return try await entry.executor.execute(
                invocation: invocation,
                context: ToolExecutionContext(
                    threadID: invocation.threadID,
                    turnID: invocation.turnID,
                    session: session
                )
            )
        } catch {
            return .failure(
                invocation: invocation,
                message: error.localizedDescription
            )
        }
    }
}
