import Foundation

/// Hosted search is separate from host-tool invocation and round budgets.
public struct AgentWebSearchPolicy: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case disabled, cached, indexed, live

        var restrictionRank: Int {
            switch self {
            case .disabled: 0
            case .cached: 1
            case .indexed: 2
            case .live: 3
            }
        }
    }

    public let mode: Mode
    /// DNS names, including their subdomains. nil is unrestricted; [] disables search.
    public let allowedDomains: [String]?

    public init(mode: Mode, allowedDomains: [String]? = nil) {
        self.mode = mode
        self.allowedDomains = allowedDomains
    }

    private enum CodingKeys: String, CodingKey { case mode, allowedDomains }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self).allKeys
        guard fields.allSatisfy({ CodingKeys(rawValue: $0.stringValue) != nil }) else {
            throw AgentDefinitionSourceError.invalidSkillDefinition()
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
    }

    func normalized() throws -> Self {
        guard let allowedDomains else { return self }
        guard allowedDomains.count <= 100 else { throw Self.invalidDomains() }
        let domains = try allowedDomains.map { raw -> String in
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasSuffix(".") { domain.removeLast() }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard domain.utf8.count <= 253, labels.count >= 2,
                  labels.allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }), labels.last?.utf8.contains(where: { (97...122).contains($0) }) == true else {
                throw Self.invalidDomains()
            }
            return domain
        }
        return .init(mode: domains.isEmpty ? .disabled : mode, allowedDomains: Self.minimalDomains(domains))
    }

    /// Intersection of domain subtrees, not string equality: example.com and
    /// docs.example.com intersect at docs.example.com.
    func narrowed(by other: Self) throws -> Self {
        let lhs = try normalized(), rhs = try other.normalized()
        let mode = lhs.mode.restrictionRank <= rhs.mode.restrictionRank ? lhs.mode : rhs.mode
        let domains: [String]?
        switch (lhs.allowedDomains, rhs.allowedDomains) {
        case let (left?, right?):
            domains = Self.minimalDomains(left.flatMap { a in
                right.compactMap { b in
                    if Self.contains(a, b) { return b }
                    if Self.contains(b, a) { return a }
                    return nil
                }
            })
        case let (left?, nil): domains = left
        case let (nil, right?): domains = right
        case (nil, nil): domains = nil
        }
        return .init(mode: domains?.isEmpty == true ? .disabled : mode, allowedDomains: domains)
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasSuffix("." + parent)
    }

    private static func minimalDomains(_ domains: [String]) -> [String] {
        let unique = Set(domains)
        return unique.filter { domain in !unique.contains { $0 != domain && contains($0, domain) } }.sorted()
    }

    private static func invalidDomains() -> AgentRuntimeError {
        .init(code: .invalidWebSearchPolicy,
            message: "Search domains must be at most 100 DNS names (ASCII or punycode), without URLs, ports, paths, IP addresses, or wildcards.")
    }
}

/// A backend advertising this value promises to enforce Request.webSearch.
/// The default policy is also the upper capability bound for a turn.
public struct AgentWebSearchCapabilities: Hashable, Sendable {
    public let defaultPolicy: AgentWebSearchPolicy
    public let supportedModes: Set<AgentWebSearchPolicy.Mode>
    public let supportsAllowedDomains: Bool

    public init(defaultPolicy: AgentWebSearchPolicy, supportedModes: Set<AgentWebSearchPolicy.Mode>, supportsAllowedDomains: Bool = false) {
        self.defaultPolicy = defaultPolicy
        self.supportedModes = supportedModes
        self.supportsAllowedDomains = supportsAllowedDomains
    }

    public func resolve(_ constraint: AgentWebSearchPolicy?) throws -> AgentWebSearchPolicy {
        let effective = try constraint.map { try defaultPolicy.narrowed(by: $0) } ?? defaultPolicy.normalized()
        guard effective.mode == .disabled || supportedModes.contains(effective.mode),
              effective.mode == .disabled || effective.allowedDomains == nil || supportsAllowedDomains else {
            throw AgentRuntimeError(code: .unsupportedBackendCapability,
                message: "The backend cannot enforce the requested hosted web-search restriction.")
        }
        return effective
    }
}

extension AgentRuntime {
    func effectiveWebSearch(request: Request, skills: ResolvedTurnSkills) async throws -> AgentWebSearchPolicy? {
        var constraint = request.webSearch
        if let skillPolicy = skills.compiledToolPolicy.webSearch {
            constraint = try constraint.map { try $0.narrowed(by: skillPolicy) } ?? skillPolicy.normalized()
        }
        guard let capabilities = await backend.webSearchCapabilities else {
            guard constraint == nil else {
                throw AgentRuntimeError(code: .unsupportedBackendCapability,
                    message: "The backend does not advertise enforcement of hosted web-search restrictions.")
            }
            return nil
        }
        return try capabilities.resolve(constraint)
    }
}
