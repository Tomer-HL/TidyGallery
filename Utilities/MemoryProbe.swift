//
//  MemoryProbe.swift
//  TidyGallery
//
//  Reads the process's real memory footprint and its remaining headroom.
//
//  Why two numbers, not one
//  ------------------------
//  Footprint alone doesn't predict an out-of-memory kill. iOS jetsam limits
//  differ by device (an iPhone SE and a Pro Max are not close) and by what else
//  is resident, so "we peaked at 380 MB" means nothing on its own.
//  `os_proc_available_memory()` reports how many bytes this process may still
//  allocate before it is killed — that is the number that actually matters when
//  the question is "does a 20,000-photo scan survive on the smallest supported
//  device?".
//
//  `phys_footprint` from `task_vm_info` is what the kernel bills against that
//  limit — the same figure Xcode's memory gauge shows — which is why it is used
//  here rather than `resident_size`, which overstates by counting shared pages.
//
//  Both calls are cheap (a `task_info` trap and a libsystem read) and allocate
//  nothing, so sampling them per page during a scan costs nothing measurable.
//

import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if os(iOS)
import os
#endif

enum MemoryProbe {

    /// One paired reading.
    struct Sample: Sendable, Equatable {
        /// Bytes the kernel bills to this process.
        let footprintBytes: Int64
        /// Bytes this process may still allocate before jetsam kills it.
        /// `nil` where the platform doesn't expose it.
        let availableBytes: Int64?
    }

    static func sample() -> Sample {
        Sample(footprintBytes: footprintBytes(), availableBytes: availableBytes())
    }

    /// Current physical footprint, or 0 if the kernel call fails (treated as
    /// "unknown" — it only ever loses us a data point, never breaks a scan).
    static func footprintBytes() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
        #else
        return 0
        #endif
    }

    /// Remaining allocation headroom before this process is jetsam-killed.
    ///
    /// Returns `nil` off-iOS, and also when the API reports 0 — which it does
    /// for processes it can't reason about, and which we must not confuse with
    /// "no memory left".
    static func availableBytes() -> Int64? {
        #if os(iOS)
        let remaining = os_proc_available_memory()
        return remaining > 0 ? Int64(remaining) : nil
        #else
        return nil
        #endif
    }
}
