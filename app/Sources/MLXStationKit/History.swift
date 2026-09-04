import Foundation

/// A bounded history of one metric, used to draw the trend charts.
public struct Series: Sendable {
    private var values: [Double] = []
    private let capacity: Int

    public init(capacity: Int = 180) { self.capacity = capacity }

    public mutating func push(_ value: Double?) {
        values.append(value ?? 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var all: [Double] { values }
    public var latest: Double? { values.last }
    public var peak: Double { values.max() ?? 0 }
    public var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    public var isEmpty: Bool { values.isEmpty }

    /// The most recent `count` samples, oldest first.
    public func window(_ count: Int) -> [Double] {
        Array(values.suffix(count))
    }
}

public struct History: Sendable {
    public var gpu = Series()
    public var gpuPower = Series()
    public var cpu = Series()
    public var bandwidth = Series()
    public var gpuMemory = Series()
    public var systemPower = Series()

    public init() {}

    public mutating func push(_ snapshot: Snapshot) {
        gpu.push(snapshot.gpu.busyPercent)
        gpuPower.push(snapshot.power.gpuWatts)
        cpu.push(snapshot.cpuPercent)
        bandwidth.push(snapshot.bandwidth.totalGBps)
        gpuMemory.push(snapshot.memory.gpuUsed.map(Double.init))
        systemPower.push(snapshot.power.systemWatts)
    }

    public mutating func reset() { self = History() }
}
