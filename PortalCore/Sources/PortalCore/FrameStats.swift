import Foundation

/// Rolling frame-interval statistics (measured, not estimated).
public struct FrameStats: Sendable {
    public let capacity: Int
    public let budget: Double
    private var samples: [Double]
    private var head = 0
    private var filled = 0

    public init(capacity: Int = 600, budgetMs: Double = 1000.0 / 60.0) {
        self.capacity = capacity
        self.budget = budgetMs
        self.samples = Array(repeating: 0, count: capacity)
    }

    public mutating func add(intervalMs: Double) {
        guard intervalMs.isFinite, intervalMs > 0, intervalMs < 1000 else { return }
        samples[head] = intervalMs
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    public struct Summary: Equatable, Sendable {
        public var count: Int
        public var meanMs: Double
        public var p95Ms: Double
        public var maxMs: Double
        public var fps: Double
        /// Share of frames slower than the budget plus a 10% allowance for
        /// display-link jitter (16.7 ms -> 18.3 ms).
        public var overBudget: Double
    }

    public func summary() -> Summary {
        guard filled > 0 else { return Summary(count: 0, meanMs: 0, p95Ms: 0, maxMs: 0, fps: 0, overBudget: 0) }
        let s = Array(samples.prefix(filled)).sorted()
        let mean = s.reduce(0, +) / Double(s.count)
        let p95 = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        let over = Double(s.filter { $0 > budget * 1.1 }.count) / Double(s.count)
        return Summary(count: s.count, meanMs: mean, p95Ms: p95, maxMs: s.last ?? 0, fps: 1000 / mean, overBudget: over)
    }

    public mutating func reset() { head = 0; filled = 0 }
}
