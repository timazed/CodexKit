/// Known protocol values used for routing. Unknown values remain in the raw
/// payload so newer provider events and items can be ignored or persisted.
enum ResponsesEventType: String {
    case rateLimits = "codex.rate_limits"
    case outputItemAdded = "response.output_item.added"
    case reasoningSummaryTextDelta = "response.reasoning_summary_text.delta"
    case webSearchInProgress = "response.web_search_call.in_progress"
    case webSearchSearching = "response.web_search_call.searching"
    case webSearchCompleted = "response.web_search_call.completed"
    case created = "response.created"
    case outputTextDelta = "response.output_text.delta"
    case outputItemDone = "response.output_item.done"
    case completed = "response.completed"
    case failed = "response.failed"
    case incomplete = "response.incomplete"

    var logsResponsePayload: Bool {
        switch self {
        case .outputItemDone, .completed, .failed, .incomplete: true
        default: false
        }
    }
}

enum ResponsesItemType: String, Sendable {
    case message
    case functionCall = "function_call"
    case functionCallOutput = "function_call_output"
    case customToolCallOutput = "custom_tool_call_output"
    case imageGenerationCall = "image_generation_call"
    case webSearchCall = "web_search_call"
    case compaction
    case compactionTrigger = "compaction_trigger"

    init?(wireValue: JSONValue?) {
        guard let rawValue = wireValue?.stringValue else { return nil }
        self.init(rawValue: rawValue)
    }

    var jsonValue: JSONValue { .string(rawValue) }
}

enum ResponsesContentType: String, Sendable {
    case inputText = "input_text"
    case outputText = "output_text"
    case inputImage = "input_image"

    init?(wireValue: JSONValue?) {
        guard let rawValue = wireValue?.stringValue else { return nil }
        self.init(rawValue: rawValue)
    }

    var jsonValue: JSONValue { .string(rawValue) }
}

enum ResponsesToolType: String {
    case function
    case webSearch = "web_search"
    case imageGeneration = "image_generation"

    var jsonValue: JSONValue { .string(rawValue) }
}
