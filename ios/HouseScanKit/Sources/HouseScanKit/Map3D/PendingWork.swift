import Foundation

/// Inputs waiting for one serial worker, at most `limit` of them: a new one pushes out the
/// oldest, so a worker slower than its inputs works on recent ones and its backlog, and the
/// memory the inputs hold, stays bounded. `DepthEstimator` queues kept frames for the depth
/// model through it.
public struct PendingWork<Item: Sendable>: Sendable {
    public let limit: Int
    private var items: [Item] = []
    /// Inputs pushed out unworked.
    public private(set) var dropped = 0

    public init(limit: Int) {
        precondition(limit >= 1, "a work queue needs room for one input, not \(limit)")
        self.limit = limit
    }

    public var count: Int { items.count }

    public mutating func add(_ item: Item) {
        items.append(item)
        if items.count > limit {
            dropped += items.count - limit
            items.removeFirst(items.count - limit)
        }
    }

    /// The oldest waiting input.
    public mutating func take() -> Item? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}

/// Values kept by key within a total cost: setting a key makes it the newest, and the oldest go
/// once the total passes `budget`. A value costing more than the whole budget is not kept.
/// `Map3DSession` holds the mesh chunks and planes ARKit sends before the map starts in it.
public struct BoundedRecent<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let budget: Int
    private let cost: @Sendable (Value) -> Int
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Oldest first.
    private var order: [Key] = []
    public private(set) var total = 0
    /// Values pushed out to stay within the budget.
    public private(set) var evicted = 0

    public init(budget: Int, cost: @escaping @Sendable (Value) -> Int) {
        self.budget = budget
        self.cost = cost
    }

    public var keys: [Key] { order }
    public var values: [Value] { order.compactMap { entries[$0]?.value } }
    public var isEmpty: Bool { order.isEmpty }

    public subscript(key: Key) -> Value? {
        get { entries[key]?.value }
        set {
            if let old = entries.removeValue(forKey: key) {
                total -= old.cost
                order.removeAll { $0 == key }
            }
            guard let newValue else { return }
            let price = cost(newValue)
            guard price <= budget else {
                evicted += 1
                return
            }
            entries[key] = (newValue, price)
            order.append(key)
            total += price
            while total > budget, let oldest = order.first {
                order.removeFirst()
                if let gone = entries.removeValue(forKey: oldest) { total -= gone.cost }
                evicted += 1
            }
        }
    }

    /// Empties it and restarts `evicted`.
    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        total = 0
        evicted = 0
    }
}
