import Foundation

/// Plain final-answer text using the same provisional/committed lifecycle as other formats.
/// Existing `stream(_:in:)` retains its original behavior, including commentary deltas.
public struct AgentTextResponseFormat: AgentOutputFormat {
    public let name: String
    public var limits: AgentStructuredOutputLimits
    public init(name: String = "text", limits: AgentStructuredOutputLimits = .init()) {
        self.name = name
        self.limits = limits
    }
    public var codecIdentifier: String { "codexkit.text/v1" }
    public var formatInstructions: String {
        "Finish tool work before the final answer. Return a single final text message."
    }
    public var persistence: AgentOutputPersistence<String>? { .json }
    public func makeDecoder() throws -> AgentTextOutputDecoder {
        try limits.validate()
        return .init(limits: limits)
    }
}

public enum AgentTextOutputEvent: Sendable { case textDelta(String) }

public actor AgentTextOutputDecoder: AgentOutputDecoder {
    public typealias Event = AgentTextOutputEvent
    public typealias Output = String
    private let limits: AgentStructuredOutputLimits
    private var source = Data()
    private var text = AgentOutputUTF8Buffer()
    private var ended = false
    init(limits: AgentStructuredOutputLimits) { self.limits = limits }
    public func consume(_ bytes: Data, into sink: AgentOutputEventSink<Event>) async throws {
        guard !ended else { throw AgentOutputError.protocolViolation("Text decoder has finished.") }
        guard bytes.count <= limits.maximumInputBytes - source.count else {
            throw AgentOutputError.limit("Text input exceeds limit.")
        }
        source.append(bytes)
        var buffer = text
        try await buffer.consume(bytes, maximumChunk: limits.maximumSemanticUnitBytes) { text in
            try await sink.emit(.textDelta(text), encodedByteCount: text.utf8.count)
        }
        if !ended { text = buffer }
    }
    public func finish(into sink: AgentOutputEventSink<Event>) throws -> String {
        guard !ended else { throw AgentOutputError.protocolViolation("Text decoder has finished.") }
        ended = true
        try text.finish()
        guard String(data: source, encoding: .utf8) != nil else {
            throw AgentOutputError.invalidOutput("Invalid text encoding.")
        }
        return String(decoding: source, as: UTF8.self)
    }
    public func cancel() {
        ended = true
        source.removeAll()
        text = .init()
    }
}
