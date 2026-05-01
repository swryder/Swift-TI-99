// Swift 99/a
//
// Scratchpad.swift
// 256-byte fast scratchpad RAM mapped at 0x8300–0x83FF on the TI-99/4A.
// This is the only directly writable CPU RAM in the base console (no
// expansion). The CPU's workspace pointer (WP) typically points here
// for register file storage.

import Foundation

/// 256-byte scratchpad RAM. The TI-99/4A's only built-in read/write memory.
final class Scratchpad: Peripheral {

    /// Plain RAM: writes store the byte for future reads. Shadow stays in sync.
    override var writesAreMemoryBacked: Bool { true }

    static let memSize = 256
    private var data = [UInt8](repeating: 0, count: memSize)

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        guard addr < Scratchpad.memSize else { return 0 }
        return data[addr]
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        guard addr < Scratchpad.memSize else { return }
        self.data[addr] = data
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "Scratchpad", index: index)
        return true
    }
}
