// Swift 99/a
//
// Peripheral.swift
// Base class for all emulated hardware peripherals (ROM, RAM, VDP, PSG, etc.).
// Every byte in the CPU memory and CRU I/O address space is mapped to a
// Peripheral via the PeripheralMap arrays in EmulatorSystem. The base class
// provides default no-op implementations so unmapped addresses silently
// return 0x00. DummyPeripheral is used as the singleton for unmapped regions.

import Foundation

/// The base peripheral interface. Not pure virtual so the base class can be used as a dummy object.
class Peripheral {
    let lock = NSRecursiveLock()
    weak var theCore: EmulatorSystem?
    var lastTimestamp: Double = 0
    var page: Int = 0
    private var formattedName: String = "Dummy_0"

    init(core: EmulatorSystem?) {
        self.theCore = core
        setIndex(name: "Dummy", index: 0)
    }

    // MARK: - Read/Write

    /// Side-effect-free read for debug/visualization purposes.
    /// Override in peripherals where read() has side effects (e.g. GROM address auto-increment).
    func peek(addr: Int) -> UInt8 {
        var cycles = 0
        return read(addr: addr, isIO: false, cycles: &cycles, accessType: .free)
    }

    func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        return 0
    }

    func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
    }

    // MARK: - Memory Fast-Path Hints
    //
    // EmulatorSystem maintains a 64KB "shadow" mirror of the CPU address
    // space. CPU memory reads can be served directly from shadow (skipping
    // the virtual `read()` call) when the peripheral's read is memory-backed
    // and stable. CPU writes update shadow only when the peripheral actually
    // stores the byte such that future reads return it. These two properties
    // let memory-backed peripherals (ROM, RAM, Cart) opt into the fast path.

    /// True if `read()` / `peek()` returns a computed value or has observable
    /// side effects (e.g. GROM auto-increment, VDP status bit clear). When
    /// false, reads at this peripheral's mapped addresses can bypass the
    /// virtual call and return the shadow byte directly.
    var readsHaveSideEffects: Bool { false }

    /// True if `write(data:)` causes future reads at the same address to
    /// return `data`. Only true for plain RAM. ROM (no-op), sound/VDP/GROM
    /// ports (writes go elsewhere), and bank-switched cart ROM (writes
    /// trigger banking, not byte storage at the written address) are all
    /// false. Used by EmulatorSystem to decide whether to mirror CPU writes
    /// into the shadow.
    var writesAreMemoryBacked: Bool { false }

    // MARK: - Lifecycle

    func initialize(index: Int) -> Bool { return true }
    func operate(timestamp: Double) -> Bool { return true }
    func cleanup() -> Bool { return true }

    // MARK: - Name

    func setIndex(name: String?, index: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let name = name {
            formattedName = "\(name)_\(index)"
        } else {
            if let underscoreIdx = formattedName.firstIndex(of: "_") {
                formattedName = String(formattedName[...underscoreIdx]) + "\(index)"
            }
        }
    }

    var name: String { return formattedName }
}

/// Singleton dummy peripheral for addresses with nothing mapped
final class DummyPeripheral: Peripheral {
    static let shared = DummyPeripheral()
    private init() {
        super.init(core: nil)
    }
}
