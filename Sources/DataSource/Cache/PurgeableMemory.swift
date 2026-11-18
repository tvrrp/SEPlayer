//
//  PurgeableMemory.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import Darwin

/// A region of memory that the system may purge while it is volatile.
///
/// The system purges volatile regions under memory pressure without asking: their pages then read as zeros. Making a
/// region non-volatile again tells whether that happened.
final class PurgeableMemory {
    /// When the system purges a volatile region, relative to the others.
    enum Order {
        /// Before any other region: for a probe of memory pressure.
        case first
        /// Early, the regions made volatile first going first: for bytes that were read already.
        case early
        /// Later, the regions made volatile last going first: for bytes far ahead of what is read.
        case late

        fileprivate var state: Int32 {
            switch self {
            case .first: Control.volatile | Control.orderingObsolete
            case .early: Control.volatile | Control.group(1) | Control.fifo
            case .late: Control.volatile | Control.group(4) | Control.lifo
            }
        }
    }

    let pointer: UnsafeMutableRawPointer
    let size: Int

    /// Whether the system purged the memory.
    var isPurged: Bool {
        var state: Int32 = 0
        guard control(Control.getState, &state) == KERN_SUCCESS else {
            return true
        }

        return state & Control.stateMask == Control.empty
    }

    /// Allocates `size` bytes, non-volatile. `nil` if the system has no memory for them.
    init?(size: Int) {
        var address: vm_address_t = 0
        // vm_allocate allocates whole pages anywhere in the address space of the task. VM_FLAGS_PURGABLE makes
        // them a region of their own that vm_purgable_control can make volatile.
        let result = vm_allocate(
            mach_task_self_,
            &address,
            vm_size_t(size),
            VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE
        )
        guard result == KERN_SUCCESS, let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            return nil
        }

        self.pointer = pointer
        self.size = size
    }

    deinit {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: pointer)), vm_size_t(size))
    }

    /// Lets the system purge the memory, in `order`.
    func makeVolatile(_ order: Order) {
        var state = order.state
        _ = control(Control.setState, &state)
    }

    /// Keeps the memory from the system.
    ///
    /// - Returns: `false` if the system purged the memory while it was volatile: its contents are gone.
    func makeNonVolatile() -> Bool {
        var state = Control.nonVolatile
        guard control(Control.setState, &state) == KERN_SUCCESS else {
            return false
        }

        return state & Control.stateMask != Control.empty
    }

    /// vm_purgable_control gets or sets the purgeable state of the region: non-volatile, volatile with an order, or
    /// empty once the system purged it. Setting a state returns the previous one in `state`.
    private func control(_ operation: vm_purgable_t, _ state: inout Int32) -> kern_return_t {
        vm_purgable_control(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: pointer)),
            operation,
            &state
        )
    }
}

/// The values of `<mach/vm_purgable.h>`, whose macros don't reach Swift.
private enum Control {
    static let setState: vm_purgable_t = 0
    static let getState: vm_purgable_t = 1

    static let stateMask: Int32 = 3
    static let nonVolatile: Int32 = 0
    static let volatile: Int32 = 1
    static let empty: Int32 = 2

    static let orderingObsolete: Int32 = 1 << 5
    static let fifo: Int32 = 0
    static let lifo: Int32 = 1 << 6

    static func group(_ group: Int32) -> Int32 { group << 8 }
}
