// Swift 99/a
//
// ROM.swift
// Simple read-only memory peripheral. Used for the console ROM (8 KB at
// 0x0000–0x1FFF) and any other read-only memory regions.

import Foundation

/// Read-only memory peripheral. Writes are silently ignored (no-op from base class).
final class ROM: Peripheral {
    let romData: [UInt8]

    init(core: EmulatorSystem?, data: [UInt8]) {
        self.romData = data
        super.init(core: core)
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        guard addr < romData.count else { return 0 }
        return romData[addr]
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "ROM", index: index)
        return true
    }
}
