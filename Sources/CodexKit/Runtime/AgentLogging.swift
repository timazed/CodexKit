import Foundation
import OSLog

public enum AgentLogLevel: Int, Sendable, Codable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
}

extension AgentLogLevel: Comparable {
    public static func < (lhs: AgentLogLevel, rhs: AgentLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AgentLogCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case auth
    case runtime
    case persistence
    case network
    case retry
    case compaction
    case tools
    case approvals
    case structuredOutput
    case memory
}

public struct AgentLogEntry: Sendable, Equatable {
    public let timestamp: Date
    public let level: AgentLogLevel
    public let category: AgentLogCategory
    public let message: String
    public let metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        level: AgentLogLevel,
        category: AgentLogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public protocol AgentLogSink: Sendable {
    func log(_ entry: AgentLogEntry)
}

public struct AnyAgentLogSink: AgentLogSink, Sendable {
    private let emit: @Sendable (AgentLogEntry) -> Void

    public init(_ emit: @escaping @Sendable (AgentLogEntry) -> Void) {
        self.emit = emit
    }

    public init<Sink: AgentLogSink>(_ sink: Sink) {
        self.emit = { entry in
            sink.log(entry)
        }
    }

    public func log(_ entry: AgentLogEntry) {
        emit(entry)
    }
}

public struct AgentConsoleLogSink: AgentLogSink, Sendable {
    public init() {}

    public func log(_ entry: AgentLogEntry) {
        FileHandle.standardError.write(Data((entry.renderedLine + "\n").utf8))
    }
}

public struct AgentOSLogSink: AgentLogSink, Sendable {
    public let subsystem: String

    public init(subsystem: String = "CodexKit") {
        self.subsystem = subsystem
    }

    public func log(_ entry: AgentLogEntry) {
        let logger = Logger(subsystem: subsystem, category: entry.category.rawValue)
        let renderedLine = entry.renderedLine
        switch entry.level {
        case .debug:
            logger.debug("\(renderedLine, privacy: .private)")
        case .info:
            logger.info("\(renderedLine, privacy: .private)")
        case .warning:
            logger.notice("\(renderedLine, privacy: .private)")
        case .error:
            logger.error("\(renderedLine, privacy: .private)")
        }
    }
}

public struct AgentLoggingConfiguration: Sendable {
    public let isEnabled: Bool
    public let minimumLevel: AgentLogLevel
    public let categories: Set<AgentLogCategory>?
    public let sink: AnyAgentLogSink?

    public init() {
        self.isEnabled = false
        self.minimumLevel = .info
        self.categories = nil
        self.sink = nil
    }

    public init(
        minimumLevel: AgentLogLevel = .info,
        categories: Set<AgentLogCategory>? = nil,
        sink: some AgentLogSink
    ) {
        self.isEnabled = true
        self.minimumLevel = minimumLevel
        self.categories = categories
        self.sink = AnyAgentLogSink(sink)
    }

    public static let disabled = AgentLoggingConfiguration()

    public static func console(
        minimumLevel: AgentLogLevel = .info,
        categories: Set<AgentLogCategory>? = nil
    ) -> AgentLoggingConfiguration {
        AgentLoggingConfiguration(
            minimumLevel: minimumLevel,
            categories: categories,
            sink: AgentConsoleLogSink()
        )
    }

    public static func osLog(
        minimumLevel: AgentLogLevel = .info,
        categories: Set<AgentLogCategory>? = nil,
        subsystem: String = "CodexKit"
    ) -> AgentLoggingConfiguration {
        AgentLoggingConfiguration(
            minimumLevel: minimumLevel,
            categories: categories,
            sink: AgentOSLogSink(subsystem: subsystem)
        )
    }

    func allows(
        level: AgentLogLevel,
        category: AgentLogCategory
    ) -> Bool {
        guard isEnabled,
              level >= minimumLevel
        else {
            return false
        }
        guard let categories else {
            return true
        }
        return categories.contains(category)
    }
}

struct AgentLogger: Sendable {
    let configuration: AgentLoggingConfiguration

    init(configuration: AgentLoggingConfiguration = .disabled) {
        self.configuration = configuration
    }

    func debug(
        _ category: AgentLogCategory,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.debug, category, message, metadata: metadata)
    }

    func info(
        _ category: AgentLogCategory,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.info, category, message, metadata: metadata)
    }

    func warning(
        _ category: AgentLogCategory,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.warning, category, message, metadata: metadata)
    }

    func error(
        _ category: AgentLogCategory,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.error, category, message, metadata: metadata)
    }

    func isVerboseEnabled(for category: AgentLogCategory) -> Bool {
        configuration.allows(level: .debug, category: category)
    }

    private func log(
        _ level: AgentLogLevel,
        _ category: AgentLogCategory,
        _ message: String,
        metadata: [String: String]
    ) {
        guard configuration.allows(level: level, category: category),
              let sink = configuration.sink
        else {
            return
        }

        sink.log(
            AgentLogEntry(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
        )
    }
}

private extension AgentLogEntry {
    var renderedLine: String {
        let formatter = ISO8601DateFormatter()
        var line = "[\(formatter.string(from: timestamp))] [\(level.renderedName)] [\(category.rawValue)] \(message)"
        if !metadata.isEmpty {
            let renderedMetadata = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            line += " | \(renderedMetadata)"
        }
        return line
    }
}

private extension AgentLogLevel {
    var renderedName: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }
}
