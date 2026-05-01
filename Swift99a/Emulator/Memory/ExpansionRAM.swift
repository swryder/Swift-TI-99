// Swift 99/a
//
// ExpansionRAM.swift
// 32 KB memory expansion for the TI-99/4A (the "32K sidecar").
// On real hardware this maps to two regions:
//   - 0x2000–0x3FFF (8 KB, "low memory")
//   - 0xA000–0xFFFF (24 KB, "high memory")
// The actual address remapping is handled in TI994A.initSystem().

import Foundation

/// 32 KB expansion RAM peripheral. Provides the additional RAM that most
/// cartridges and disk-based software require beyond the 256-byte scratchpad.
final class ExpansionRAM: Peripheral {

    /// Plain RAM: writes store the byte for future reads. Shadow stays in sync.
    override var writesAreMemoryBacked: Bool { true }

    static let memSize = 32 * 1024
    private var data = [UInt8](repeating: 0, count: memSize)

    override func initialize(index: Int) -> Bool {
        setIndex(name: "32KRAM", index: index)
        return true
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        guard addr < ExpansionRAM.memSize else { return 0 }
        return data[addr]
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        guard addr < ExpansionRAM.memSize else { return }
        self.data[addr] = data
    }
}
