import Foundation
import CodexKit

func streamedCompactionReply(encryptedContent: String = "Summary", additionalOutput: [JSONValue] = []) -> Data {
    let items = additionalOutput + [.object(["type": .string("compaction"),
        "id": .string("cmp_1"), "encrypted_content": .string(encryptedContent)])]
    var lines = items.enumerated().map { index, item in
        let envelope = JSONValue.object(["type": .string("response.output_item.done"),
            "output_index": .number(Double(index)), "item": item])
        return "data: " + String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self) + "\n\n"
    }
    lines.append("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"compact-response\"}}\n\n")
    return Data(lines.joined().utf8)
}
