import Foundation

public struct AgentAssistantContentDelta: Sendable {
    public let threadID: String
    public let turnID: String
    public let messageID: String
    public let contentIndex: Int
    public let phase: AgentMessagePhase?
    public let text: String
    public init(threadID: String, turnID: String, messageID: String, contentIndex: Int = 0,
                phase: AgentMessagePhase?, text: String) {
        self.threadID = threadID; self.turnID = turnID; self.messageID = messageID
        self.contentIndex = contentIndex; self.phase = phase; self.text = text
    }
}

struct AnyAgentOutputExecution: Sendable {
    let instructions: String
    let consume: @Sendable (AgentAssistantContentDelta) async throws -> Void
    let message: @Sendable (AgentMessage, String) async throws -> Void
    let finish: @Sendable () async throws -> AgentMessage
    let cancel: @Sendable () async -> Void
    let began: @Sendable () -> Bool
}

/// Terminal delivery is assembled synchronously only after storage has returned success.
final class AgentOutputResultBox<Event: Sendable, Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (AgentOutputContext, Output)?
    private var started = false
    private var failure: (AgentOutputContext?, AgentOutputFailure)?
    func begin() { lock.withLock { started = true } }
    var hasStarted: Bool { lock.withLock { started } }
    func stage(_ context: AgentOutputContext, _ output: Output) { lock.withLock { value = (context, output) } }
    func fail(_ context: AgentOutputContext?, _ error: Error) {
        guard !(error is CancellationError) else { return }
        lock.withLock { if failure == nil { failure = (context, .init(message: String(error.localizedDescription.prefix(2_048)))) } }
    }
    func terminal(_ events: [AgentEvent], error: Error?) -> [AgentOutputEvent<Event, Output>] {
        let committed = lock.withLock { value }
        var result: [AgentOutputEvent<Event, Output>] = []
        if error != nil, let failure = lock.withLock({ failure }) { result.append(.validationFailed(failure.0, failure.1)) }
        for event in events {
            result.append(.lifecycle(event))
            if case let .messageCommitted(message) = event, error == nil, let committed,
               message.id == committed.0.messageID { result.append(.outputCommitted(committed.0, committed.1)) }
        }
        return result
    }
}

actor AgentOutputSession<Format: AgentOutputFormat> {
    typealias Event = AgentOutputEvent<Format.Decoder.Event, Format.Decoder.Output>
    let format: Format
    let decoder: Format.Decoder
    let executionID: UUID
    let threadID: String
    let channel: AgentEventChannel<Event>
    let box: AgentOutputResultBox<Format.Decoder.Event, Format.Decoder.Output>
    var context: AgentOutputContext?
    var source = Data()
    var candidate: AgentMessage?
    var lastContentIndex = -1
    var pending: [String: (bytes: Data, index: Int)] = [:]
    var pendingBytes = 0
    var fedBytes = 0
    var finished = false

    init(format: Format, decoder: Format.Decoder, executionID: UUID, threadID: String,
         channel: AgentEventChannel<Event>, box: AgentOutputResultBox<Format.Decoder.Event, Format.Decoder.Output>) {
        self.format = format; self.decoder = decoder; self.executionID = executionID; self.threadID = threadID
        self.channel = channel; self.box = box
    }

    nonisolated var erased: AnyAgentOutputExecution {
        .init(instructions: format.formatInstructions, consume: {
            do { try await self.consume($0) } catch { await self.report(error); throw error }
        }, message: {
            do { try await self.message($0, turnID: $1) } catch { await self.report(error); throw error }
        }, finish: {
            do { return try await self.finish() } catch { await self.report(error); throw error }
        },
              cancel: { await self.decoder.cancel() }, began: { self.box.hasStarted })
    }

    private func report(_ error: Error) { box.fail(context, error) }

    func bind(messageID: String, turnID: String) throws -> AgentOutputContext {
        if let context {
            guard context.messageID == messageID, context.turnID == turnID else {
                throw AgentOutputError.protocolViolation("A structured output must belong to one final message.")
            }
            return context
        }
        guard !messageID.isEmpty else { throw AgentOutputError.protocolViolation("Missing output message identity.") }
        let value = AgentOutputContext(executionID: executionID, threadID: threadID,
                                      turnID: turnID, messageID: messageID, documentID: UUID())
        context = value
        return value
    }

    func sink(_ context: AgentOutputContext) -> AgentOutputEventSink<Format.Decoder.Event> {
        let limit = format.limits.maximumSemanticUnitBytes
        let channel = channel
        return .init { event, size in
            guard size >= 0, size <= limit else { throw AgentOutputError.limit("Semantic event exceeds its byte limit.") }
            try await channel.yield(.format(context, event), byteCount: size)
        }
    }

    func consume(_ delta: AgentAssistantContentDelta) async throws {
        guard delta.phase != .commentary else { return }
        if delta.phase == nil {
            guard context?.messageID != delta.messageID else {
                throw AgentOutputError.protocolViolation("Final output lost its phase identity.")
            }
            var part = pending[delta.messageID] ?? (Data(), -1)
            guard delta.contentIndex >= max(part.index, 0), delta.contentIndex <= part.index + 1 else {
                throw AgentOutputError.protocolViolation("Output content parts arrived out of order.")
            }
            let bytes = Data(delta.text.utf8)
            guard bytes.count <= format.limits.maximumInputBytes - pendingBytes,
                  pending.count < format.limits.maximumSemanticUnits || pending[delta.messageID] != nil else {
                throw AgentOutputError.limit("Unclassified output exceeds limits.")
            }
            part.bytes.append(bytes); part.index = delta.contentIndex
            pending[delta.messageID] = part; pendingBytes += bytes.count
            return
        }
        guard candidate == nil, !finished else { throw AgentOutputError.protocolViolation("Text followed a completed final message.") }
        let context = try bind(messageID: delta.messageID, turnID: delta.turnID)
        if let part = pending.removeValue(forKey: delta.messageID) {
            pendingBytes -= part.bytes.count
            source = part.bytes; lastContentIndex = part.index
            box.begin()
            try await decoder.consume(part.bytes, into: sink(context))
            fedBytes += part.bytes.count
        }
        guard delta.contentIndex >= max(lastContentIndex, 0), delta.contentIndex <= lastContentIndex + 1 else {
            throw AgentOutputError.protocolViolation("Output content parts arrived out of order.")
        }
        lastContentIndex = delta.contentIndex
        let bytes = Data(delta.text.utf8)
        guard bytes.count <= format.limits.maximumInputBytes - source.count else { throw AgentOutputError.limit("Output input limit exceeded.") }
        source.append(bytes)
        box.begin()
        try await decoder.consume(bytes, into: sink(context))
        fedBytes += bytes.count
    }

    func message(_ message: AgentMessage, turnID: String) async throws {
        if message.phase == .commentary {
            if let part = pending.removeValue(forKey: message.id) { pendingBytes -= part.bytes.count }
            guard context?.messageID != message.id else { throw AgentOutputError.protocolViolation("Final output changed to commentary.") }
            return
        }
        guard candidate == nil else { throw AgentOutputError.protocolViolation("Multiple final output messages.") }
        let context = try bind(messageID: message.id, turnID: turnID)
        let bytes = Data(message.text.utf8)
        guard bytes.count <= format.limits.maximumInputBytes else { throw AgentOutputError.limit("Output input limit exceeded.") }
        if let part = pending.removeValue(forKey: message.id) {
            pendingBytes -= part.bytes.count
            guard part.bytes == bytes else { throw AgentOutputError.protocolViolation("Completed text differs from unclassified streamed output.") }
        }
        if fedBytes > 0 {
            guard bytes == source else { throw AgentOutputError.protocolViolation("Completed text differs from streamed output.") }
        } else {
            source = bytes
            box.begin()
            try await decoder.consume(bytes, into: sink(context))
        }
        candidate = message
    }

    func finish() async throws -> AgentMessage {
        guard !finished, let context, var candidate else { throw AgentOutputError.invalidOutput("Missing final structured output.") }
        guard pending.isEmpty else { throw AgentOutputError.protocolViolation("Unfinished unclassified output messages.") }
        finished = true
        let output = try await decoder.finish(into: sink(context))
        try await format.validateFinal(output)
        try Task.checkCancellation()
        if let persistence = format.persistence {
            let encoded = try persistence.encode(output)
            guard encoded.count <= format.limits.maximumOutputBytes else { throw AgentOutputError.limit("Encoded output exceeds limit.") }
            let representation = AgentOutputRepresentation(envelopeVersion: 1, codecIdentifier: format.codecIdentifier,
                formatVersion: format.formatVersion, context: context, schema: format.schemaRepresentation,
                rawText: candidate.text, encodedOutput: encoded)
            let payload = try JSONValue.encoding(representation)
            guard try JSONEncoder().encode(payload).count <= AgentStoreLimits.maximumEmbeddedPayloadByteCount else {
                throw AgentOutputError.limit("Output plus persistence envelope exceeds storage limit.")
            }
            candidate.structuredOutput = .init(formatName: format.name, payload: payload)
        }
        try AgentStoredPayloadValidator.validateMessage(candidate)
        box.stage(context, output)
        return candidate
    }
}
