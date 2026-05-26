import Foundation

struct ProcessResourceUsage: Equatable {
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0

    var formattedCPU: String {
        "\(Int(cpuPercent.rounded()))%"
    }

    var formattedMemory: String {
        let megabytes = Double(memoryBytes) / 1_048_576
        return "\(Int(megabytes.rounded())) MB"
    }
}
