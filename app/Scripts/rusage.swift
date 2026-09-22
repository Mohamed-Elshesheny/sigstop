import Darwin
import Foundation

let pid = pid_t(CommandLine.arguments[1]) ?? 0
var info = rusage_info_v4()
let status = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
}
guard status == 0 else { exit(1) }
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let cpu = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
print(String(format: "%.0f %llu %llu %llu", cpu, info.ri_interrupt_wkups, info.ri_billed_energy, info.ri_phys_footprint))
