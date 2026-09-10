import CodexKit
import CodexKitSQLite
import CodexKitRealm
import Foundation

enum MacDemoPersistence: String, Codable, CaseIterable, Identifiable {
    case file, sqlite, realm
    var id: String { rawValue }
    var title: String {
        switch self { case .file: "File"; case .sqlite: "SQLite"; case .realm: "Realm" }
    }
}

struct MacDemoRuntimeOptions: Codable, Equatable {
    var persistence: MacDemoPersistence = .file
    var webSearch = true
    var imageGeneration = true
    var automaticMemory = false
}

enum MacDemoPersona: String, CaseIterable, Identifiable {
    case general, support, planner, travel
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .support: "Support persona"; case .planner: "Planner persona"; case .travel: "Travel skill" }
    }
    var stack: AgentPersonaStack? {
        switch self {
        case .general, .travel: nil
        case .support: .init(layers: [.init(name: "support", instructions: "You are a calm, concise shipping support assistant.")])
        case .planner: .init(layers: [.init(name: "planner", instructions: "Plan carefully. Explain tradeoffs and implementation steps.")])
        }
    }
}

enum MacDemoRuntimeFactory {
    static let memoryNamespace = "mac-demo"
    static let memoryScope: MemoryScope = "preferences"
    static let memoryContext = AgentMemoryContext(namespace: memoryNamespace, scopes: [memoryScope])
    static let memoryDefaults = MemoryWriterDefaults(namespace: memoryNamespace, scope: memoryScope, category: "preference")
    static let reviewer = AgentPersonaStack(layers: [.init(name: "reviewer", instructions: "For this reply, act as a strict reviewer. Call out risks first.")])

    static func stores(at stateURL: URL, options: MacDemoRuntimeOptions) throws -> (any RuntimeStateStoring, any MemoryStoring) {
        let directory = stateURL.deletingLastPathComponent()
        switch options.persistence {
        case .file:
            return (FileRuntimeStateStore(url: stateURL), try SQLiteMemoryStore(storageDirectory: directory.appendingPathComponent("File")))
        case .sqlite:
            return (try SQLiteRuntimeStateStore(storageDirectory: directory),
                    try SQLiteMemoryStore(storageDirectory: directory))
        case .realm:
            return (try RealmRuntimeStateStore(storageDirectory: directory),
                    try RealmMemoryStore(storageDirectory: directory))
        }
    }

    static let travelSkill = AgentSkill(id: "travel_planner", name: "Travel Planner",
        instructions: "Use travel_planner_build_day_plan to prepare a sample itinerary before giving a concise travel plan.",
        executionPolicy: .init(allowedToolNames: ["travel_planner_build_day_plan"],
            requiredToolNames: ["travel_planner_build_day_plan"], maxToolCalls: 1))

    static var tools: [AgentRuntime.ToolRegistration] {
        let emptySchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
        var tools: [AgentRuntime.ToolRegistration] = [
            .init(definition: .init(name: "travel_planner_build_day_plan", description: "Build a deterministic sample itinerary for a destination.",
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "destination": .object(["type": .string("string")])]), "required": .array([.string("destination")])])),
                executor: .init { invocation, _ in
                    let destination = invocation.arguments.objectValue?["destination"]?.stringValue ?? "your destination"
                    return .success(invocation: invocation, text: "Sample plan for \(destination): morning walking tour, afternoon museum, evening local dinner. No bookings made.")
                }),
            .init(definition: .init(name: "demo_prepare_draft", description: "Prepare a local sample support draft. Requires approval; sends nothing.",
                inputSchema: emptySchema, approvalPolicy: .requiresApproval,
                approvalMessage: "Prepare this sample draft locally? Nothing will be sent."), executor: .init { invocation, _ in
                    .success(invocation: invocation, text: "Sample draft prepared locally. Nothing was sent.")
                })
        ]
        for (name, output) in [("demo_lookup_weather", "Sample Sydney weather: sunny, 22°C."),
                                ("demo_lookup_transport", "Sample Sydney transport: trains every 10 minutes.")] {
            tools.append(.init(definition: .init(name: name, description: output + " Independent sample lookup.",
                inputSchema: emptySchema, approvalPolicy: .automatic, supportsParallelExecution: true),
                executor: .init { invocation, _ in
                    try await Task.sleep(for: .milliseconds(1_500))
                    return .success(invocation: invocation, text: output)
                }))
        }
        return tools
    }
}

/// Bounded in-memory diagnostics; metadata and credentials are never copied into this UI log.
final class MacDemoLogSink: AgentLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func log(_ entry: AgentLogEntry) {
        lock.withLock {
            entries.append("[\(entry.category.rawValue)] \(entry.message)")
            if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        }
    }
    func snapshot() -> String { lock.withLock { entries.joined(separator: "\n") } }
}
