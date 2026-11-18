//
//  MemoryPressure.swift
//  SEPlayer
//
//  Created by tvrrp on 10.10.2026.
//

import Darwin
import os
import SEPlayerCommon

/// Tells whether the system is short of memory.
final class MemoryPressure {
    /// Whether memory is short now.
    var isUnderPressure: Bool {
        let isUnderPressure = checkPressure()
        if isUnderPressure != wasUnderPressure {
            wasUnderPressure = isUnderPressure
            logChange(isUnderPressure: isUnderPressure)
        }

        return isUnderPressure
    }

    // A small volatile region that the system purges before any other is the probe: once it is purged, the system
    // has started taking memory back. Where the platform tells how much memory the process may still use, that
    // counts too.

    /// Below this much memory left to the process, it is short of memory.
    private let minimumAvailableBytes: Int
    private let probeSize: Int

    private var probe: PurgeableMemory?
    private var wasUnderPressure = false

    /// Memory the process may still use, where the platform tells.
    private var availableBytes: Int? {
        #if (os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
        let availableBytes = os_proc_available_memory()
        return availableBytes > 0 ? availableBytes : nil
        #else
        return nil
        #endif
    }

    init(
        minimumAvailableBytes: Int = 64 * 1024 * 1024, // 64 MB
        probeSize: Int = Int(getpagesize())
    ) {
        self.minimumAvailableBytes = minimumAvailableBytes
        self.probeSize = probeSize
    }

    private func checkPressure() -> Bool {
        // A purged probe is replaced, so the next check asks afresh.
        if let probe, probe.isPurged {
            self.probe = nil
            return true
        }

        if probe == nil {
            probe = PurgeableMemory(size: probeSize)
            probe?.makeVolatile(.first)
        }
        guard probe != nil else { return true }
        guard let availableBytes else { return false }

        return availableBytes < minimumAvailableBytes
    }

    private func logChange(isUnderPressure: Bool) {
        guard isUnderPressure else {
            SELogger.info(.cache, "Memory is no longer short")
            return
        }

        if let availableBytes {
            SELogger.info(.cache, "Memory is short: \(availableBytes / 1024 / 1024) MB left to the process")
        } else {
            SELogger.info(.cache, "Memory is short")
        }
    }
}
