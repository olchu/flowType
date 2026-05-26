import Darwin
import Foundation

final class ProcessResourceMonitorService {
    private var previousCPUTime: Double?
    private var previousUptime: TimeInterval?

    func currentUsage() -> ProcessResourceUsage {
        ProcessResourceUsage(
            cpuPercent: averagedCPUPercent(),
            memoryBytes: currentMemoryBytes()
        )
    }

    private func currentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func averagedCPUPercent() -> Double {
        guard let currentCPUTime = currentCPUTime() else { return 0 }

        let currentUptime = ProcessInfo.processInfo.systemUptime
        defer {
            previousCPUTime = currentCPUTime
            previousUptime = currentUptime
        }

        guard let previousCPUTime, let previousUptime else { return 0 }

        let cpuDelta = currentCPUTime - previousCPUTime
        let uptimeDelta = currentUptime - previousUptime
        guard cpuDelta >= 0, uptimeDelta > 0 else { return 0 }

        return cpuDelta / uptimeDelta * 100
    }

    private func currentCPUTime() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return timeValueInSeconds(info.user_time) + timeValueInSeconds(info.system_time)
    }

    private func timeValueInSeconds(_ timeValue: time_value_t) -> Double {
        Double(timeValue.seconds) + Double(timeValue.microseconds) / 1_000_000
    }
}
