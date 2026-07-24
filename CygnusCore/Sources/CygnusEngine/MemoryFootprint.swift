import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Process memory accounting, shared by the engine's index throttle and
// the app-side memory governor. `phys_footprint` is the same number the
// OS meters against (Activity Monitor "Memory", jetsam/limit checks) —
// resident dirty + compressed + IOKit, not virtual address space — so a
// budget expressed against it means what the user thinks it means.

public enum MemoryFootprint {
    /// Current process physical footprint in bytes, or nil if the
    /// kernel query fails (never fabricate a number — callers treat nil
    /// as "unknown, don't throttle").
    public static func currentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }
}
