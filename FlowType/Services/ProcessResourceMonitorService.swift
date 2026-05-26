import Darwin
import Foundation

struct ProcessResourceMonitorService {
    func currentUsage() -> ProcessResourceUsage {
        ProcessResourceUsage(
            cpuPercent: currentCPUPercent(),
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

    private func currentCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let threadsResult = task_threads(mach_task_self_, &threadList, &threadCount)
        guard threadsResult == KERN_SUCCESS, let threadList else { return 0 }

        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var totalCPU: Double = 0

        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)

            let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                    thread_info(
                        threadList[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        reboundPointer,
                        &count
                    )
                }
            }

            guard infoResult == KERN_SUCCESS else { continue }

            let isIdle = (info.flags & TH_FLAGS_IDLE) != 0
            if !isIdle {
                totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }

        return totalCPU
    }
}
