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
    private enum Window: String { case primary, secondary }

    private static let defaultLimitID = "codex"
    static func headers(_ response: HTTPURLResponse) -> [AgentRateLimitSnapshot] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var families: Set<String> = [defaultLimitID]
        for key in headers.keys where key.hasPrefix("x-") {
            for suffix in ["-primary-used-percent", "-secondary-used-percent"] where key.hasSuffix(suffix) {
                families.insert(String(key.dropFirst(2).dropLast(suffix.count)))
            }
        }
        var credits: AgentCreditsSnapshot?
        if let hasValue = headers["x-codex-credits-has-credits"], let has = Bool(hasValue),
           let unlimitedValue = headers["x-codex-credits-unlimited"], let unlimited = Bool(unlimitedValue) {
            credits = .init(hasCredits: has, unlimited: unlimited, balance: headers["x-codex-credits-balance"])
        }
        return families.sorted().compactMap { family in
            let primary = headerWindow(.primary, family: family, headers: headers)
            let secondary = headerWindow(.secondary, family: family, headers: headers)
            guard primary != nil || secondary != nil || (family == defaultLimitID && credits != nil) else { return nil }
            return .init(limitID: family.replacingOccurrences(of: "-", with: "_"),
                         limitName: headers["x-\(family)-limit-name"], primary: primary, secondary: secondary,
                         credits: credits)
        }
    }

    private static func headerWindow(_ name: Window, family: String,
        headers: [String: String]) -> AgentRateLimitWindow? {
        let prefix = "x-\(family)-\(name.rawValue)"
        guard let rawUsed = headers["\(prefix)-used-percent"],
              let used = Double(rawUsed), used.isFinite else { return nil }
        // Optional telemetry must not invalidate an otherwise usable window.
        let minutes: Int? = if let raw = headers["\(prefix)-window-minutes"] { Int(raw) } else { nil }
        let resetTimestamp: Double? = if let raw = headers["\(prefix)-reset-at"] { Double(raw) } else { nil }
        return .init(usedPercent: used, windowDurationMinutes: minutes, resetsAt: date(resetTimestamp))
    }

    static func event(_ value: [String: JSONValue]) -> AgentRateLimitSnapshot {
        func window(_ name: Window) -> AgentRateLimitWindow? {
            guard let object = value["rate_limits"]?.objectValue?[name.rawValue]?.objectValue,
                  let used = number(object["used_percent"]), used.isFinite else { return nil }
            return .init(usedPercent: used,
                         windowDurationMinutes: integer(object["window_minutes"]),
                         resetsAt: date(number(object["reset_at"])))
        }
        var credits: AgentCreditsSnapshot?
        if let c = value["credits"]?.objectValue,
           case let .bool(has) = c["has_credits"], case let .bool(unlimited) = c["unlimited"] {
            credits = .init(hasCredits: has, unlimited: unlimited, balance: c["balance"]?.stringValue)
        }
        let id = value["metered_limit_name"]?.stringValue ?? value["limit_name"]?.stringValue ?? defaultLimitID
        return .init(limitID: id.lowercased().replacingOccurrences(of: "-", with: "_"),
                     primary: window(.primary), secondary: window(.secondary), credits: credits)
    }

    private static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number) = value else { return nil }
        return Int(exactly: number)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }
}
