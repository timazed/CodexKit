import Foundation

public struct AgentRateLimitWindow: Codable, Hashable, Sendable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?
    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    public init(usedPercent: Double, windowDurationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct AgentCreditsSnapshot: Codable, Hashable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

/// Account-level limits, distinct from a turn's token usage. Missing windows are unknown.
public struct AgentRateLimitSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { limitID }
    public let limitID: String
    public let limitName: String?
    public let primary: AgentRateLimitWindow?
    public let secondary: AgentRateLimitWindow?
    public let credits: AgentCreditsSnapshot?

    public init(limitID: String, limitName: String? = nil, primary: AgentRateLimitWindow? = nil,
                secondary: AgentRateLimitWindow? = nil, credits: AgentCreditsSnapshot? = nil) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
    }
}

enum CodexRateLimitParser {
    static func headers(_ response: HTTPURLResponse) -> [AgentRateLimitSnapshot] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var families: Set<String> = ["codex"]
        for key in headers.keys where key.hasPrefix("x-") {
            for suffix in ["-primary-used-percent", "-secondary-used-percent"] where key.hasSuffix(suffix) {
                families.insert(String(key.dropFirst(2).dropLast(suffix.count)))
            }
        }
        let credits: AgentCreditsSnapshot? = {
            guard let has = headers["x-codex-credits-has-credits"].flatMap(Bool.init),
                  let unlimited = headers["x-codex-credits-unlimited"].flatMap(Bool.init) else { return nil }
            return .init(hasCredits: has, unlimited: unlimited, balance: headers["x-codex-credits-balance"])
        }()
        return families.sorted().compactMap { family in
            func window(_ name: String) -> AgentRateLimitWindow? {
                let prefix = "x-\(family)-\(name)"
                guard let used = headers["\(prefix)-used-percent"].flatMap(Double.init), used.isFinite else { return nil }
                return .init(usedPercent: used,
                             windowDurationMinutes: headers["\(prefix)-window-minutes"].flatMap(Int.init),
                             resetsAt: headers["\(prefix)-reset-at"].flatMap(Double.init).flatMap(date))
            }
            let primary = window("primary"), secondary = window("secondary")
            guard primary != nil || secondary != nil || (family == "codex" && credits != nil) else { return nil }
            return .init(limitID: family.replacingOccurrences(of: "-", with: "_"),
                         limitName: headers["x-\(family)-limit-name"], primary: primary, secondary: secondary,
                         credits: credits)
        }
    }

    static func event(_ data: Data) -> AgentRateLimitSnapshot? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              value["type"]?.stringValue == "codex.rate_limits" else { return nil }
        func window(_ name: String) -> AgentRateLimitWindow? {
            guard let object = value["rate_limits"]?.objectValue?[name]?.objectValue,
                  let used = number(object["used_percent"]), used.isFinite else { return nil }
            return .init(usedPercent: used,
                         windowDurationMinutes: number(object["window_minutes"]).flatMap { Int(exactly: $0) },
                         resetsAt: number(object["reset_at"]).flatMap(date))
        }
        var credits: AgentCreditsSnapshot?
        if let c = value["credits"]?.objectValue,
           case let .bool(has) = c["has_credits"], case let .bool(unlimited) = c["unlimited"] {
            credits = .init(hasCredits: has, unlimited: unlimited, balance: c["balance"]?.stringValue)
        }
        let id = value["metered_limit_name"]?.stringValue ?? value["limit_name"]?.stringValue ?? "codex"
        return .init(limitID: id.lowercased().replacingOccurrences(of: "-", with: "_"),
                     primary: window("primary"), secondary: window("secondary"), credits: credits)
    }

    private static func date(_ seconds: Double) -> Date? {
        seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }
    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }
}
