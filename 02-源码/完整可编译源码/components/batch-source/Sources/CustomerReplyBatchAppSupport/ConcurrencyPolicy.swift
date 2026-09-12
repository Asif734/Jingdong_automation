import Darwin
import Foundation

public enum SystemMemoryProbe {
    public static func availableBytes() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return ProcessInfo.processInfo.physicalMemory }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return ProcessInfo.processInfo.physicalMemory
        }
        let pages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        return pages * UInt64(pageSize)
    }
}

public enum GenerationAdmissionDecision: Equatable, Sendable {
    case admit
    case deferForMemory
    case deferForBackpressure(until: Date)
}

public final class AdaptiveConcurrencyPolicy: @unchecked Sendable {
    private let hardMemoryFloorBytes: UInt64
    private let lock = NSLock()
    private var backpressureUntil: Date?

    public init(hardMemoryFloorBytes: UInt64 = UInt64(1) << 30) {
        self.hardMemoryFloorBytes = hardMemoryFloorBytes
    }

    public func decision(
        availableMemoryBytes: UInt64,
        now: Date
    ) -> GenerationAdmissionDecision {
        guard availableMemoryBytes >= hardMemoryFloorBytes else { return .deferForMemory }
        lock.lock()
        defer { lock.unlock() }
        guard let until = backpressureUntil else { return .admit }
        if now >= until {
            backpressureUntil = nil
            return .admit
        }
        return .deferForBackpressure(until: until)
    }

    public func recordBackpressure(now: Date) {
        lock.lock()
        backpressureUntil = now.addingTimeInterval(60)
        lock.unlock()
    }

    public func recordSuccess(now: Date) {
        lock.lock()
        if let until = backpressureUntil, now >= until {
            backpressureUntil = nil
        }
        lock.unlock()
    }

}
