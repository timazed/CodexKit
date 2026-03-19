import Foundation

public struct StoredRuntimeState: Codable, Hashable, Sendable {
    public var threads: [AssistantThread]
    public var messagesByThread: [String: [AssistantMessage]]

    public init(
        threads: [AssistantThread] = [],
        messagesByThread: [String: [AssistantMessage]] = [:]
    ) {
        self.threads = threads
        self.messagesByThread = messagesByThread
    }

    public static let empty = StoredRuntimeState()
}

public protocol RuntimeStateStoring: Sendable {
    func loadState() async throws -> StoredRuntimeState
    func saveState(_ state: StoredRuntimeState) async throws
}

public actor InMemoryRuntimeStateStore: RuntimeStateStoring {
    private var state: StoredRuntimeState

    public init(initialState: StoredRuntimeState = .empty) {
        state = initialState
    }

    public func loadState() async throws -> StoredRuntimeState {
        state
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        self.state = state
    }
}

public actor FileRuntimeStateStore: RuntimeStateStoring {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
    }

    public func loadState() async throws -> StoredRuntimeState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(StoredRuntimeState.self, from: data)
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
