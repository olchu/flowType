import Darwin
import Foundation

final class ProcessResourceMonitorService {
    private var previousCPUTime: Double?
    private var previousUptime: TimeInterval?

    func currentUsage() -> ProcessResourceUsage {
        let info = basicTaskInfo()
        return ProcessResourceUsage(
            cpuPercent: averagedCPUPercent(currentCPUTime: info.map(cpuTime(of:))),
            memoryBytes: info.map { UInt64($0.resident_size) } ?? 0
        )
    }

    private func averagedCPUPercent(currentCPUTime: Double?) -> Double {
        guard let currentCPUTime else { return 0 }

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

    private func basicTaskInfo() -> mach_task_basic_info? {
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

        return result == KERN_SUCCESS ? info : nil
    }

    private func cpuTime(of info: mach_task_basic_info) -> Double {
        timeValueInSeconds(info.user_time) + timeValueInSeconds(info.system_time)
    }

    private func timeValueInSeconds(_ timeValue: time_value_t) -> Double {
        Double(timeValue.seconds) + Double(timeValue.microseconds) / 1_000_000
    }
}
