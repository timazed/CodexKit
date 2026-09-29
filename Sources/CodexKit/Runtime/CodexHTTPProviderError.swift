import Foundation

/// Shared error-envelope decoding. Callers retain structured metadata separately;
/// this type never retains the full provider payload.
struct CodexHTTPProviderError: Decodable {
    let message: String?

    private enum CodingKeys: String, CodingKey { case error, message, detail }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? container.decode(StreamErrorPayload.self, forKey: .error))?.message
            ?? (try? container.decode(String.self, forKey: .error))
            ?? (try? container.decode(String.self, forKey: .message))
            ?? (try? container.decode(String.self, forKey: .detail))
    }
}
