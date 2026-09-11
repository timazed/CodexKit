import Foundation

enum StructuredStreamParserMode {
    case visible
    case structured
}

enum StructuredStreamParsingEvent {
    case visibleText(String)
    case structuredOutputPartial(JSONValue)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
}

enum StructuredStreamFinalResult {
    case none
    case committed(JSONValue)
    case invalid(AgentStructuredOutputValidationFailure)
}

struct StructuredStreamExtraction {
    let visibleText: String
    let finalResult: StructuredStreamFinalResult
}

struct CodexResponsesStructuredStreamParser {
    static let openTag = "<codexkit-structured-output>"
    static let closeTag = "</codexkit-structured-output>"

    private var mode: StructuredStreamParserMode = .visible
    private var pending = ""
    private var structuredBuffer = ""
    private var lastPartial: JSONValue?
    private var structuredByteCount = 0
    private var boundary = StructuredJSONBoundary()
    private var attemptedSnapshot = false
    private(set) var snapshotDecodeAttempts = 0
    private let maximumPayloadBytes: Int

    init(maximumPayloadBytes: Int = AgentStoreLimits.maximumEmbeddedPayloadByteCount) {
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
    }

    mutating func consume(delta: String) throws -> [StructuredStreamParsingEvent] {
        pending.append(delta)
        var events: [StructuredStreamParsingEvent] = []

        while try consumeAvailableContent(into: &events) {
        }

        return events
    }

    mutating func finalize(rawMessage: String) -> StructuredStreamExtraction {
        defer { self = Self(maximumPayloadBytes: maximumPayloadBytes) }
        return Self.extractFinal(from: rawMessage, maximumPayloadBytes: maximumPayloadBytes)
    }

    private mutating func snapshotEvents(
        stage: AgentStructuredOutputValidationStage
    ) -> [StructuredStreamParsingEvent] {
        guard !attemptedSnapshot else { return [] }
        attemptedSnapshot = true
        snapshotDecodeAttempts += 1
        guard let data = structuredBuffer.data(using: .utf8) else {
            return []
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard value != lastPartial else {
                return []
            }
            lastPartial = value
            return [.structuredOutputPartial(value)]
        } catch {
            if stage == .committed {
                return [
                    .structuredOutputValidationFailed(
                        AgentStructuredOutputValidationFailure(
                            stage: .committed,
                            message: error.localizedDescription,
                            rawPayload: structuredBuffer
                        )
                    ),
                ]
            }
            return []
        }
    }

    private mutating func consumeAvailableContent(
        into events: inout [StructuredStreamParsingEvent]
    ) throws -> Bool {
        switch mode {
        case .visible:
            return consumeVisibleContent(into: &events)
        case .structured:
            return try consumeStructuredContent(into: &events)
        }
    }

    private mutating func consumeVisibleContent(
        into events: inout [StructuredStreamParsingEvent]
    ) -> Bool {
        if let range = pending.range(of: Self.openTag) {
            let visible = String(pending[..<range.lowerBound])
            if !visible.isEmpty {
                events.append(.visibleText(visible))
            }
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            mode = .structured
            return true
        }

        let retainCount = Self.trailingMatchLength(in: pending, against: Self.openTag)
        let emitCount = pending.count - retainCount
        guard emitCount > 0 else {
            return false
        }

        let index = pending.index(pending.startIndex, offsetBy: emitCount)
        let visible = String(pending[..<index])
        if !visible.isEmpty {
            events.append(.visibleText(visible))
        }
        pending.removeSubrange(pending.startIndex..<index)
        return true
    }

    private mutating func consumeStructuredContent(
        into events: inout [StructuredStreamParsingEvent]
    ) throws -> Bool {
        if let range = pending.range(of: Self.closeTag) {
            try appendStructured(pending[..<range.lowerBound])
            events.append(contentsOf: snapshotEvents(stage: .partial))
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            mode = .visible
            return true
        }

        let retainCount = Self.trailingMatchLength(in: pending, against: Self.closeTag)
        let emitCount = pending.count - retainCount
        guard emitCount > 0 else {
            return false
        }

        let index = pending.index(pending.startIndex, offsetBy: emitCount)
        try appendStructured(pending[..<index])
        pending.removeSubrange(pending.startIndex..<index)
        if boundary.isComplete { events.append(contentsOf: snapshotEvents(stage: .partial)) }
        return true
    }

    private mutating func appendStructured(_ fragment: Substring) throws {
        let count = fragment.utf8.count
        guard count <= maximumPayloadBytes - structuredByteCount else {
            throw AgentRuntimeError(code: .structuredOutputTooLarge, message: "Structured output exceeded its byte limit.")
        }
        structuredByteCount += count
        structuredBuffer.append(contentsOf: fragment)
        boundary.consume(fragment.utf8)
    }

    private static func trailingMatchLength(
        in buffer: String,
        against marker: String
    ) -> Int {
        let maxLength = min(buffer.count, marker.count - 1)
        guard maxLength > 0 else {
            return 0
        }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = buffer.suffix(length)
            if marker.hasPrefix(String(suffix)) {
                return length
            }
        }

        return 0
    }

    private static func extractFinal(from rawMessage: String, maximumPayloadBytes: Int) -> StructuredStreamExtraction {
        guard let openRange = rawMessage.range(of: openTag) else {
            return StructuredStreamExtraction(
                visibleText: rawMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                finalResult: .none
            )
        }

        let remaining = rawMessage[openRange.upperBound...]
        guard let closeRange = remaining.range(of: closeTag) else {
            return StructuredStreamExtraction(
                visibleText: rawMessage[..<openRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                finalResult: .invalid(
                    AgentStructuredOutputValidationFailure(
                        stage: .committed,
                        message: "The structured output block was never closed.",
                        rawPayload: remaining.utf8.count <= maximumPayloadBytes ? String(remaining) : nil
                    )
                )
            )
        }

        let payload = String(remaining[..<closeRange.lowerBound])
        let suffix = remaining[closeRange.upperBound...]
        let visibleText = (String(rawMessage[..<openRange.lowerBound]) + String(suffix))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.utf8.count <= maximumPayloadBytes else {
            return StructuredStreamExtraction(visibleText: visibleText, finalResult: .invalid(.init(
                stage: .committed, message: "Structured output exceeded its byte limit."
            )))
        }

        let trailing = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trailing.contains(openTag) {
            return StructuredStreamExtraction(
                visibleText: visibleText,
                finalResult: .invalid(
                    AgentStructuredOutputValidationFailure(
                        stage: .committed,
                        message: "Multiple structured output blocks were emitted in one turn.",
                        rawPayload: payload
                    )
                )
            )
        }

        guard let data = payload.data(using: .utf8) else {
            return StructuredStreamExtraction(
                visibleText: visibleText,
                finalResult: .invalid(
                    AgentStructuredOutputValidationFailure(
                        stage: .committed,
                        message: "The structured output payload could not be read as UTF-8.",
                        rawPayload: payload
                    )
                )
            )
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return StructuredStreamExtraction(
                visibleText: visibleText,
                finalResult: .committed(value)
            )
        } catch {
            return StructuredStreamExtraction(
                visibleText: visibleText,
                finalResult: .invalid(
                    AgentStructuredOutputValidationFailure(
                        stage: .committed,
                        message: error.localizedDescription,
                        rawPayload: payload
                    )
                )
            )
        }
    }
}

/// A lexical boundary check only; JSONDecoder remains the authority on syntax.
/// Every byte is visited once, instead of decoding every incomplete prefix.
private struct StructuredJSONBoundary {
    private var started = false
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var scalar = false
    private(set) var isComplete = false

    mutating func consume<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes {
            guard !isComplete else { return }
            let whitespace = byte == 32 || byte == 9 || byte == 10 || byte == 13
            if !started {
                if whitespace { continue }
                started = true
                scalar = byte != 123 && byte != 91 && byte != 34
            }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false; if depth == 0 { isComplete = true } }
            } else {
                switch byte {
                case 34: inString = true
                case 123, 91: depth += 1
                case 125, 93: depth -= 1; if depth <= 0 { isComplete = true }
                default: if scalar && whitespace { isComplete = true }
                }
            }
        }
    }
}
