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

    mutating func consume(delta: String) -> [StructuredStreamParsingEvent] {
        pending.append(delta)
        var events: [StructuredStreamParsingEvent] = []

        while consumeAvailableContent(into: &events) {
        }

        return events
    }

    func finalize(rawMessage: String) -> StructuredStreamExtraction {
        Self.extractFinal(from: rawMessage)
    }

    private mutating func snapshotEvents(
        stage: AgentStructuredOutputValidationStage
    ) -> [StructuredStreamParsingEvent] {
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
    ) -> Bool {
        switch mode {
        case .visible:
            return consumeVisibleContent(into: &events)
        case .structured:
            return consumeStructuredContent(into: &events)
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
    ) -> Bool {
        if let range = pending.range(of: Self.closeTag) {
            structuredBuffer.append(contentsOf: pending[..<range.lowerBound])
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
        structuredBuffer.append(contentsOf: pending[..<index])
        pending.removeSubrange(pending.startIndex..<index)
        events.append(contentsOf: snapshotEvents(stage: .partial))
        return true
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

    private static func extractFinal(from rawMessage: String) -> StructuredStreamExtraction {
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
                        rawPayload: String(remaining)
                    )
                )
            )
        }

        let payload = String(remaining[..<closeRange.lowerBound])
        let suffix = remaining[closeRange.upperBound...]
        let visibleText = (String(rawMessage[..<openRange.lowerBound]) + String(suffix))
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
