import Combine

/// Registry access is protected by the observation center's lock. Inactive
/// subjects keep their identity only while a publisher/subscriber owns them.
struct AgentObservationSubjects<Value> {
    private final class WeakSubject {
        weak var value: CurrentValueSubject<Value, Never>?
        init(_ value: CurrentValueSubject<Value, Never>) { self.value = value }
    }

    let initialValue: Value
    private var active: [String: CurrentValueSubject<Value, Never>] = [:]
    private var inactive: [String: WeakSubject] = [:]

    init(initialValue: Value) { self.initialValue = initialValue }

    mutating func subject(for id: String) -> CurrentValueSubject<Value, Never> {
        if let value = active[id] { return value }
        let value = inactive.removeValue(forKey: id)?.value
            ?? CurrentValueSubject<Value, Never>(initialValue)
        active[id] = value
        return value
    }

    mutating func deactivate(_ id: String) -> CurrentValueSubject<Value, Never>? {
        inactive = inactive.filter { $0.value.value != nil }
        guard let value = active.removeValue(forKey: id) else { return inactive[id]?.value }
        inactive[id] = WeakSubject(value)
        return value
    }
}
