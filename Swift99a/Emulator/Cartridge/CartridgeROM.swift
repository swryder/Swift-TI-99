// Swift 99/a
//
// CartridgeROM.swift
// Peripheral for cartridge ROM mapped at CPU address 0x6000–0x7FFF.
//
// Supports multiple banking schemes:
//   - Standard ROM: Single 8 KB bank (no bank switching)
//   - Banked 378:   Non-inverted bank selection via address bits on write
//   - Banked 379:   Inverted bank selection (used by some third-party carts)
//   - MBX:          Lower 4 KB fixed, upper 4 KB banked, plus 1 KB RAM at 0x6C00
//
// Bank switching is triggered by writes to the cartridge address space.
// The bank number is derived from the write address, not the data byte
// (except for MBX which uses a register at 0x6FFE).

import Foundation

final class CartridgeROM: Peripheral {
    private let romData: [UInt8]
    private let cartType: CartridgeType
    private let bankMask: Int

    // Bank state — volatile, changes on writes to cartridge space
    private var currentBank: Int = 0

    // MBX 1KB RAM at 0x6C00-0x6FFF (offset 0x0C00-0x0FFF in cartridge space)
    private var mbxRAM = [UInt8](repeating: 0, count: 1024)

    init(core: EmulatorSystem, image: CartridgeImage) {
        if let rom = image.romData {
            self.romData = [UInt8](rom)
        } else {
            self.romData = []
        }
        self.cartType = image.type
        self.bankMask = image.bankMask
        super.init(core: core)
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "CartROM", index: index)
        currentBank = 0
        return true
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        // MBX RAM area: 0x0C00-0x0FFF in cartridge-relative addressing
        if cartType == .mbx && addr >= 0x0C00 && addr < 0x1000 {
            return mbxRAM[addr - 0x0C00]
        }

        guard !romData.isEmpty else { return 0 }

        let bankOffset: Int
        if cartType == .mbx {
            // MBX: lower 4KB (0x0000-0x0FFF) is fixed bank 0
            // upper 4KB (0x1000-0x1FFF) is bank-switched
            if addr < 0x1000 {
                bankOffset = addr
            } else {
                bankOffset = (currentBank * 0x1000) + (addr - 0x1000)
            }
        } else {
            // Standard and banked: full 8KB bank selection
            bankOffset = (currentBank * 8192) + addr
        }

        guard bankOffset < romData.count else { return 0 }
        return romData[bankOffset]
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        // MBX RAM writes — store the byte and mirror to shadow so the CPU's
        // fast-path read returns the new value next time.
        if cartType == .mbx && addr >= 0x0C00 && addr < 0x1000 {
            mbxRAM[addr - 0x0C00] = data
            theCore?.updateShadowByte(sysAddr: 0x6000 + addr, data: data)
            return
        }

        // MBX bank register at 0x6FFE (addr 0x0FFE relative)
        if cartType == .mbx && addr == 0x0FFE {
            currentBank = Int(data) & bankMask
            mbxRAM[addr - 0x0C00] = data
            // Bank flip changes the upper 4KB of cart space; refresh whole
            // 8KB region for simplicity.
            theCore?.refreshShadowRange(sysAddr: 0x6000, length: 0x2000)
            return
        }

        // Bank switching for 378/379 and standard ROM (writes to ROM space trigger bank switch)
        guard bankMask > 0 else { return }

        switch cartType {
        case .banked378, .rom:
            // Non-inverted: bank selected by address bits
            currentBank = (addr >> 1) & bankMask
            theCore?.refreshShadowRange(sysAddr: 0x6000, length: 0x2000)

        case .banked379:
            // Inverted: bank selected by inverted address bits
            currentBank = (~(addr >> 1)) & bankMask
            theCore?.refreshShadowRange(sysAddr: 0x6000, length: 0x2000)

        default:
            break
        }
    }
}
