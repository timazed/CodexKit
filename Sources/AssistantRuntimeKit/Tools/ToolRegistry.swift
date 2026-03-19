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

public actor ToolRegistry {
    private struct Entry: Sendable {
        let definition: ToolDefinition
        let executor: AnyToolExecutor
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register(
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

    public func replace(
        _ definition: ToolDefinition,
        executor: AnyToolExecutor
    ) throws {
        guard ToolDefinition.isValidName(definition.name) else {
            throw ToolRegistryError.invalidToolName(definition.name)
        }

        entries[definition.name] = Entry(definition: definition, executor: executor)
    }

    public func definition(named name: String) -> ToolDefinition? {
        entries[name]?.definition
    }

    public func allDefinitions() -> [ToolDefinition] {
        entries.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    public func execute(
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
