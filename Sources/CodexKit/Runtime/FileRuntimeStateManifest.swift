import Foundation

struct FileRuntimeStateManifest: Codable {
    static let currentStorageVersion = 3

    let storageVersion: Int
    let generation: String?
    let threads: [AgentThread]
    let summariesByThread: [String: AgentThreadSummary]
    let contextStateByThread: [String: PersistedAgentThreadContextState]
    let nextHistorySequenceByThread: [String: Int]
    private let legacyContextStateByThread: [String: AgentThreadContextState]?

    init(
        generation: String,
        threads: [AgentThread],
        summariesByThread: [String: AgentThreadSummary],
        contextStateByThread: [String: PersistedAgentThreadContextState],
        nextHistorySequenceByThread: [String: Int]
    ) {
        self.storageVersion = Self.currentStorageVersion
        self.generation = generation
        self.threads = threads
        self.summariesByThread = summariesByThread
        self.contextStateByThread = contextStateByThread
        self.nextHistorySequenceByThread = nextHistorySequenceByThread
        self.legacyContextStateByThread = nil
    }

    func contextState(
        for threadID: String,
        using attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentThreadContextState? {
        if let legacyContextStateByThread {
            return legacyContextStateByThread[threadID]
        }
        return try contextStateByThread[threadID]?.decode(using: attachmentStore)
    }

    func decodedContextStates(
        using attachmentStore: RuntimeAttachmentStore
    ) throws -> [String: AgentThreadContextState] {
        if let legacyContextStateByThread {
            return legacyContextStateByThread
        }
        return try Dictionary(uniqueKeysWithValues: contextStateByThread.map { threadID, state in
            (threadID, try state.decode(using: attachmentStore))
        })
    }

    func validate() throws {
        guard (1 ... Self.currentStorageVersion).contains(storageVersion) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.storageVersion],
                debugDescription: "Unsupported file runtime state storage version \(storageVersion)."
            ))
        }
        if storageVersion >= 2 {
            guard let generation, UUID(uuidString: generation) != nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.generation],
                    debugDescription: "Generation-based runtime state requires a valid UUID generation."
                ))
            }
        } else if generation != nil {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.generation],
                debugDescription: "Legacy runtime state must not declare a generation."
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion
        case generation
        case threads
        case summariesByThread
        case contextStateByThread
        case nextHistorySequenceByThread
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.storageVersion = try container.decode(Int.self, forKey: .storageVersion)
        self.generation = try container.decodeIfPresent(String.self, forKey: .generation)
        self.threads = try container.decode([AgentThread].self, forKey: .threads)
        self.summariesByThread = try container.decode(
            [String: AgentThreadSummary].self,
            forKey: .summariesByThread
        )
        self.nextHistorySequenceByThread = try container.decode(
            [String: Int].self,
            forKey: .nextHistorySequenceByThread
        )
        if storageVersion >= Self.currentStorageVersion {
            self.contextStateByThread = try container.decode(
                [String: PersistedAgentThreadContextState].self,
                forKey: .contextStateByThread
            )
            self.legacyContextStateByThread = nil
        } else {
            self.contextStateByThread = [:]
            self.legacyContextStateByThread = try container.decode(
                [String: AgentThreadContextState].self,
                forKey: .contextStateByThread
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageVersion, forKey: .storageVersion)
        try container.encodeIfPresent(generation, forKey: .generation)
        try container.encode(threads, forKey: .threads)
        try container.encode(summariesByThread, forKey: .summariesByThread)
        try container.encode(contextStateByThread, forKey: .contextStateByThread)
        try container.encode(nextHistorySequenceByThread, forKey: .nextHistorySequenceByThread)
    }
}

struct FileRuntimeStateVersionProbe: Decodable {
    let storageVersion: Int?
}
