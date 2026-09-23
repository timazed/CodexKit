import Foundation

/// Structural preflight detects duplicate keys before Foundation can discard them.
/// Foundation subsequently validates number/string lexical syntax and decodes exact source bytes.
enum AgentStrictJSON {
    static func validate(_ data: Data, maximumDepth: Int) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw invalid("Invalid UTF-8.") }
        var parser = Scanner(bytes: Array(data), maximumDepth: maximumDepth)
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw invalid("Trailing JSON content.") }
        _ = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func invalid(_ text: String) -> AgentOutputError { .invalidOutput(text) }

    private struct Scanner {
        let bytes: [UInt8]
        let maximumDepth: Int
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() { while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 } }
        mutating func expect(_ byte: UInt8) throws {
            whitespace()
            guard current == byte else { throw invalid("Invalid JSON framing.") }
            index += 1
        }
        mutating func string() throws -> String {
            whitespace()
            let start = index
            try expect(34)
            while let byte = current {
                index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if byte == 92 {
                    guard current != nil else { break }
                    index += 1
                }
            }
            throw invalid("Unterminated JSON string.")
        }
        mutating func value(depth: Int) throws {
            guard depth < maximumDepth else { throw AgentOutputError.limit("JSON nesting limit exceeded.") }
            whitespace()
            guard let byte = current else { throw invalid("Empty or incomplete JSON record.") }
            switch byte {
            case 123:
                index += 1; whitespace()
                var keys = Set<String>()
                if current == 125 { index += 1; return }
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw invalid("Duplicate JSON object key: \(key)") }
                    try expect(58); try value(depth: depth + 1); whitespace()
                    if current == 125 { index += 1; return }
                    try expect(44)
                }
            case 91:
                index += 1; whitespace()
                if current == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace()
                    if current == 93 { index += 1; return }
                    try expect(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while let byte = current, ![9, 10, 13, 32, 44, 93, 125].contains(byte) { index += 1 }
                guard index > start else { throw invalid("Missing JSON value.") }
            }
        }
    }
}
