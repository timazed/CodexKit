import Foundation

/// An authoritative attachment store may opt in to checking provider file IDs.
/// Return false only for confirmed absence. Unknown IDs and access/backend errors
/// must retain the reference, allowing the provider to resolve it normally.
public protocol AgentImageAvailabilityChecking: Sendable {
    func isResolvable(fileID: String) async throws -> Bool
}

public extension AgentImageAvailabilityChecking {
    func isResolvable(fileID: String) async throws -> Bool { true }
}

/// Port of codex-rs/core/src/context_manager/image_availability.rs (cb66dbecf).
/// Only message and tool-output input images participate; arbitrary JSON,
/// generated-image results, inline images, and remote URLs are untouched.
enum CodexResponsesImageAvailability {
    static func prepare(_ items: [JSONValue], checker: (any AgentImageAvailabilityChecking)?) async throws -> [JSONValue] {
        try Task.checkCancellation()
        guard let checker else { return items }
        let ids = Set(items.flatMap { content(in: $0).compactMap(fileID) })
        guard !ids.isEmpty else { return items }
        let missing = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var iterator = ids.makeIterator()
            func enqueue(_ id: String) {
                group.addTask {
                    try Task.checkCancellation()
                    do { return (id, try await checker.isResolvable(fileID: id)) }
                    catch {
                        try Task.checkCancellation()
                        // Access failures are not evidence that an image is absent.
                        return (id, true)
                    }
                }
            }
            for _ in 0..<min(8, ids.count) {
                if let id = iterator.next() { enqueue(id) }
            }
            var missing = Set<String>()
            while let (id, resolvable) = try await group.next() {
                if !resolvable { missing.insert(id) }
                if let next = iterator.next() { enqueue(next) }
            }
            return missing
        }
        try Task.checkCancellation()
        return items.map { item in
            guard var object = item.objectValue, let key = contentKey(in: item),
                  let values = object[key]?.arrayValue else { return item }
            let replaced = values.indices.filter { index in fileID(values[index]).map { missing.contains($0) } ?? false }
            guard !replaced.isEmpty else { return item }
            object[key] = .array(values.map { part in
                guard let id = fileID(part), missing.contains(id) else { return part }
                return .object(["type": .string("input_text"), "text": .string("[image unavailable]")])
            })
            if key == "content" {
                // Match set_annotated_content: annotate only the replacement as
                // harness-owned, preserving positional attribution for other parts.
                let field = "internal_chat_message_metadata_passthrough"
                var metadata = object[field]?.objectValue ?? [:]
                let oldKinds = metadata["content_item_kinds"]?.arrayValue ?? []
                let oldSources = metadata["content_item_metadata"]?.arrayValue ?? []
                let unknown: JSONValue = .object(["provenance": .object(["type": .string("unknown")])])
                var kinds = values.indices.map { $0 < oldKinds.count ? oldKinds[$0] : .string("unknown") }
                var sources = values.indices.map { $0 < oldSources.count ? oldSources[$0] : unknown }
                for index in replaced {
                    kinds[index] = .string("images.unavailable")
                    sources[index] = .object(["provenance": .object(["type": .string("harness"), "hook": .bool(false)])])
                }
                metadata["content_item_kinds"] = .array(kinds)
                metadata["content_item_metadata"] = .array(sources)
                object[field] = .object(metadata)
            }
            return .object(object)
        }
    }

    private static func fileID(_ value: JSONValue) -> String? {
        guard let object = value.objectValue, object["type"] == .string("input_image") else { return nil }
        return object["file_id"]?.stringValue
    }

    private static func contentKey(in item: JSONValue) -> String? {
        switch item.objectValue?["type"]?.stringValue {
        case "message": return "content"
        case "function_call_output", "custom_tool_call_output": return "output"
        default: return nil
        }
    }

    private static func content(in item: JSONValue) -> [JSONValue] {
        guard let key = contentKey(in: item) else { return [] }
        return item.objectValue?[key]?.arrayValue ?? []
    }
}
