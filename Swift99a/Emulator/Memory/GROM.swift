// Swift 99/a
//
// GROM.swift
// Emulation of the TI-99/4A GROM (Graphics ROM) subsystem.
//
// GROM is a proprietary TI memory device with these characteristics:
//   - All GROM chips share a single 64 KB address space (up to 8 chips × 8 KB)
//   - Auto-incrementing address counter with prefetch (read-ahead) mechanism
//   - Each chip has an independent 13-bit counter that wraps within its 8 KB block
//   - Two-byte address write sequence (MSB first, then LSB)
//   - Address reads are destructive: return high byte, then scramble the counter
//   - GRAM (writable GROM) support via per-chip writability flags
//   - On the TI-99/4A, console GROMs occupy 0x0000–0x5FFF; cartridge
//     GROMs start at 0x6000

import Foundation

/// GROM (Graphics ROM) peripheral for the TI-99/4A.
/// All GROM instances share a single static 64 KB address space and counter.
final class GROM: Peripheral {

    /// GROM data reads auto-increment the shared 16-bit address counter,
    /// and address-port reads clear/return latched state. Both have side
    /// effects, so reads cannot be served from shadow.
    override var readsHaveSideEffects: Bool { true }

    static let MODE_ADDRESS = 1
    static let MODE_WRITE = 2

    // Shared state across all GROM instances
    private static var gromData = [UInt8](repeating: 0, count: 64 * 1024)
    private static var gromAddress: Int = 0
    private static var grmAccess: Int = 2
    private static var grmPrefetch: Int = 0

    // Per-chip writability flags (8 chips × 8K each = 64K).
    // All default to false (read-only). Only GRAM devices set these to true.
    private static var bWritable = [Bool](repeating: false, count: 8)

    init(core: EmulatorSystem?, data: [UInt8], baseAddress: Int) {
        super.init(core: core)
        guard baseAddress + data.count <= 64 * 1024 else {
            print("GROM memory overrun, failed to load.")
            return
        }
        for i in 0..<data.count {
            GROM.gromData[baseAddress + i] = data[i]
        }
    }

    func loadAdditionalData(_ data: [UInt8], baseAddress: Int) {
        guard baseAddress + data.count <= 64 * 1024 else {
            print("GROM memory overrun, failed to load.")
            return
        }
        for i in 0..<data.count {
            GROM.gromData[baseAddress + i] = data[i]
        }
    }

    static func resetSharedState() {
        gromAddress = 0
        grmAccess = 2
        grmPrefetch = 0
        gromData = [UInt8](repeating: 0, count: 64 * 1024)
        bWritable = [Bool](repeating: false, count: 8)
    }

    /// Set writability for a specific 8K GROM chip (0-7).
    /// Only GRAM devices should be set writable.
    static func setWritable(chip: Int, writable: Bool) {
        bWritable[chip & 7] = writable
    }

    /// Clear only cartridge GROM area (0x6000+), preserving console GROMs
    static func clearCartridgeGROM() {
        for i in 0x6000..<(64 * 1024) {
            gromData[i] = 0
        }
    }

    private func incrementAddress() {
        // Each GROM chip has a 13-bit counter (8K range). The top 3 bits
        // (GROM select) are remembered but not incremented. When the
        // counter reaches the end of an 8K block, it wraps to the
        // beginning of that same block.
        let base = GROM.gromAddress & 0xE000
        GROM.gromAddress = ((GROM.gromAddress + 1) & 0x1FFF) | base
    }

    override func peek(addr: Int) -> UInt8 {
        // Return GROM data at current address without modifying any shared state
        if addr & GROM.MODE_ADDRESS != 0 || addr & GROM.MODE_WRITE != 0 {
            return 0
        }
        return GROM.gromData[GROM.gromAddress]
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        if addr & GROM.MODE_WRITE != 0 { return 0 }

        GROM.grmAccess = 2

        if addr & GROM.MODE_ADDRESS != 0 {
            // Address read is destructive: returns high byte, then shifts
            // the address so the low byte appears in both positions.
            // This matches real GROM hardware behavior.
            let z = UInt8((GROM.gromAddress & 0xFF00) >> 8)
            GROM.gromAddress = ((GROM.gromAddress & 0xFF) << 8) | (GROM.gromAddress & 0xFF)
            if accessType != .free { cycles += 13 }
            return z
        } else {
            // Data read with prefetch
            let z = UInt8(GROM.grmPrefetch & 0xFF)
            GROM.grmPrefetch = Int(GROM.gromData[GROM.gromAddress])
            incrementAddress()
            if accessType != .free { cycles += 19 }
            return z
        }
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        guard addr & GROM.MODE_WRITE != 0 else { return }

        if addr & GROM.MODE_ADDRESS != 0 {
            // Write GROM address
            GROM.gromAddress = ((GROM.gromAddress << 8) | Int(data)) & 0xFFFF
            GROM.grmAccess -= 1
            if GROM.grmAccess == 0 {
                GROM.grmAccess = 2
                if accessType != .free { cycles += 21 }
                // Prefetch
                GROM.grmPrefetch = Int(GROM.gromData[GROM.gromAddress])
                incrementAddress()
            } else {
                if accessType != .free { cycles += 15 }
            }
        } else {
            // Data write (for GRAM support)
            GROM.grmAccess = 2
            // GRAM writes go to address-1 due to prefetch
            let realAddr = (GROM.gromAddress - 1) & 0xFFFF
            // Only allow writes to chips marked as writable (GRAM).
            // Standard GROMs are read-only; writes are silently ignored.
            if GROM.bWritable[(realAddr & 0xE000) >> 13] {
                GROM.gromData[realAddr] = data
            }
            // Update prefetch and increment address regardless of writability
            GROM.grmPrefetch = Int(GROM.gromData[GROM.gromAddress])
            incrementAddress()
            if accessType != .free { cycles += 22 }
        }
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "GROM", index: index)
        return true
    }
}
