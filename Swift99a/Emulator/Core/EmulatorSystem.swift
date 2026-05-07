// Swift 99/a
//
// EmulatorSystem.swift
// Base class for all emulated systems (e.g. TI-99/4A). Provides the memory
// and I/O bus infrastructure, interrupt management, PC interception hooks,
// and debug/visualization helpers. Concrete subclasses (like TI994A) wire up
// their specific peripheral map, memory layout, and system tick logic.

import Foundation
import SwiftUI

// MARK: - Memory Access Tracker

/// Lightweight tracker for memory read/write activity visualization.
/// Uses raw buffer pointers for minimal hot-path overhead.
/// All access must occur on the emulator queue.
///
/// Heat is stored as `Float` rather than `UInt8` so that wall-clock decay
/// (`heat *= factor`) doesn't lose fractional precision per step. With UInt8,
/// `floor(heat * factor)` discarded a fractional part on every snapshot — and
/// since 60-fps snapshots run 4× as often as 15-fps, the cumulative truncation
/// caused hot bytes to fade visibly faster at higher snapshot rates, even
/// though the wall-clock half-life was the same. Float storage eliminates that
/// asymmetry: the underlying heat curve evolves identically and is only
/// truncated to UInt8 at output time.
final class MemoryAccessTracker {
    let size: Int

    private let readHeatStorage: UnsafeMutablePointer<Float>
    private let writeHeatStorage: UnsafeMutablePointer<Float>
    let readHeat: UnsafeMutableBufferPointer<Float>
    let writeHeat: UnsafeMutableBufferPointer<Float>

    /// Wall-clock half-life of the access sparkle, in seconds. Decay is
    /// applied per elapsed time — not per snapshot — so the fade looks
    /// identical regardless of whether snapshots come at 15 fps, 60 fps,
    /// or any irregular rate.
    var decayHalfLife: TimeInterval = 0.25  // 250 ms

    /// Heat added per memory access. Larger than 1 so a single isolated access
    /// stays visible for ~one half-life of decay; with increment=1 a sparse
    /// access would round to UInt8 0 immediately after one decay step
    /// regardless of snapshot rate, producing only one frame of flicker
    /// (very different perceived durations at 15 fps vs 60 fps).
    static let accessIncrement: Float = 2.0

    private var lastDecayTime: CFAbsoluteTime

    init(size: Int) {
        self.size = size
        readHeatStorage = .allocate(capacity: size)
        readHeatStorage.initialize(repeating: 0, count: size)
        writeHeatStorage = .allocate(capacity: size)
        writeHeatStorage.initialize(repeating: 0, count: size)
        readHeat = UnsafeMutableBufferPointer(start: readHeatStorage, count: size)
        writeHeat = UnsafeMutableBufferPointer(start: writeHeatStorage, count: size)
        lastDecayTime = CFAbsoluteTimeGetCurrent()
    }

    deinit {
        readHeatStorage.deinitialize(count: size)
        readHeatStorage.deallocate()
        writeHeatStorage.deinitialize(count: size)
        writeHeatStorage.deallocate()
    }

    /// Record a read access. Called from the hot path.
    @inline(__always)
    func recordRead(address: Int) {
        readHeat[address] += Self.accessIncrement
    }

    /// Record a write access. Called from the hot path.
    @inline(__always)
    func recordWrite(address: Int) {
        writeHeat[address] += Self.accessIncrement
    }

    /// Copy current heat values (clamped to UInt8 0..255) into the provided
    /// destinations and apply wall-clock-based exponential decay. The decay
    /// factor for this call is `(1/2)^(elapsed / decayHalfLife)`, so the fade
    /// rate is independent of how often this method is invoked.
    func snapshotAndDecayInto(reads readsDest: UnsafeMutableRawPointer,
                              writes writesDest: UnsafeMutableRawPointer) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastDecayTime
        lastDecayTime = now

        let factor = Float(min(max(pow(0.5, elapsed / decayHalfLife), 0.0), 1.0))

        let rDst = readsDest.assumingMemoryBound(to: UInt8.self)
        let wDst = writesDest.assumingMemoryBound(to: UInt8.self)
        for i in 0..<size {
            let r = readHeat[i]
            let w = writeHeat[i]
            rDst[i] = UInt8(min(r, 255.0))
            wDst[i] = UInt8(min(w, 255.0))
            readHeat[i] = r * factor
            writeHeat[i] = w * factor
        }
    }
}

/// Base class for all emulated systems. Provides memory/IO mapping, interrupt management, etc.
class EmulatorSystem {
    let coreLock = NSRecursiveLock()

    // Per-byte peripheral routing tables. Derived classes (e.g. TI994A) allocate
    // these to match their address space sizes and populate them during initSystem().
    var memorySpaceRead: [PeripheralMap] = []
    var memorySpaceWrite: [PeripheralMap] = []
    var ioSpaceRead: [PeripheralMap] = []
    var ioSpaceWrite: [PeripheralMap] = []
    var memorySize: Int = 0   // CPU address space size (e.g. 65536 for 64KB)
    var ioSize: Int = 0       // CRU I/O space size (e.g. 4096 for TI-99/4A)

    /// Wall-clock timestamp advanced by the emulation controller each tick.
    var currentTimestamp: Double = 0.0
    var displayBuffer: DisplayBuffer?
    var audioEngine: AudioEngine?

    /// Memory access tracker for visualization (nil = no overhead in hot path)
    var accessTracker: MemoryAccessTracker?

    /// Callback invoked after each runSystem tick (~1000 Hz) for CPU-synced visualization.
    /// Set/cleared on emulatorQueue only.
    var memoryMapCallback: (() -> Void)?

    /// Shadow mirror of the readable byte at every CPU address. Populated
    /// when `claimRead` maps a peripheral (via `peek()`), kept in sync by
    /// `writeMemoryByte` for memory-backed writes, and refreshed on cart
    /// bank switches via `refreshShadowRange`. Acts as the source of truth
    /// for the CPU memory read fast path: when `memorySpaceReadFast[addr]`
    /// is non-zero, `readMemoryByte` / `peekMemoryByte` skip the virtual
    /// `read()` call and return `shadowMemory[addr]` directly.
    private(set) var shadowMemory: UnsafeMutablePointer<UInt8>?
    private var shadowMemoryCapacity: Int = 0

    /// Per-address flag (1 byte each) parallel to `memorySpaceRead`. `1`
    /// means the address is memory-backed (read can come from shadow); `0`
    /// means the peripheral's `read()` has side effects and must be called.
    /// Set during `claimRead` from the peripheral's `readsHaveSideEffects`.
    private var memorySpaceReadFast: UnsafeMutablePointer<UInt8>?

    /// Per-address flag (1 byte each) parallel to `memorySpaceWrite`. `1`
    /// means a CPU write should mirror the byte into `shadowMemory`; `0`
    /// means the write doesn't store a byte readable at this address (ROM,
    /// VDP ports, sound, cart-bank-switch). Set during `claimWrite` from
    /// the peripheral's `writesAreMemoryBacked`.
    private var memorySpaceWriteShadow: UnsafeMutablePointer<UInt8>?

    // Interrupt and hold state (bitmask-based, one bit per device/level)
    private var hold: UInt32 = 0         // HOLD requests from DMA devices
    private var holdAck: UInt32 = 0      // Acknowledged holds
    private var intReqLevel: UInt32 = 0  // Pending interrupt request levels (bitmask)
    private var nmiReq: Bool = false     // Non-maskable interrupt pending

    init() {}

    deinit {
        if let shadow = shadowMemory {
            shadow.deinitialize(count: shadowMemoryCapacity)
            shadow.deallocate()
        }
        if let p = memorySpaceReadFast {
            p.deinitialize(count: shadowMemoryCapacity)
            p.deallocate()
        }
        if let p = memorySpaceWriteShadow {
            p.deinitialize(count: shadowMemoryCapacity)
            p.deallocate()
        }
    }

    /// Allocate shadow + parallel flag arrays the first time a read is
    /// claimed. `memorySize` must be set by the subclass before any claim.
    private func ensureShadowAllocated() {
        if shadowMemory == nil && memorySize > 0 {
            let shadow = UnsafeMutablePointer<UInt8>.allocate(capacity: memorySize)
            shadow.initialize(repeating: 0, count: memorySize)
            shadowMemory = shadow

            let readFast = UnsafeMutablePointer<UInt8>.allocate(capacity: memorySize)
            readFast.initialize(repeating: 0, count: memorySize)  // default: slow
            memorySpaceReadFast = readFast

            let writeShadow = UnsafeMutablePointer<UInt8>.allocate(capacity: memorySize)
            writeShadow.initialize(repeating: 0, count: memorySize)  // default: don't mirror
            memorySpaceWriteShadow = writeShadow

            shadowMemoryCapacity = memorySize
        }
    }

    // MARK: - System Lifecycle (override in subclass)

    func initSystem() -> Bool { return false }
    func deInitSystem() -> Bool { return false }
    func runSystem(microSeconds: Int) -> Bool { return false }

    // MARK: - Memory Claiming
    // These methods let peripherals register themselves for specific addresses
    // during system initialization. Each byte can be independently routed for
    // reads and writes, allowing ROM overlay, write-through, etc.

    /// Assign a peripheral to handle reads at `sysAddr` in CPU memory space.
    func claimRead(sysAddr: Int, peripheral: Peripheral, periphAddr: Int) -> Bool {
        guard sysAddr < memorySize else { return false }
        ensureShadowAllocated()
        memorySpaceRead[sysAddr].updateMap(who: peripheral, addr: periphAddr, waitStates: nil)
        // Seed shadow with the current readable byte. For memory-backed
        // peripherals (the common case) this is the canonical value; CPU
        // writes keep it in sync. For side-effect peripherals (VDP/GROM/etc.)
        // shadow is unused — readMemoryByte falls through to the virtual call.
        shadowMemory?[sysAddr] = peripheral.peek(addr: periphAddr)
        memorySpaceReadFast?[sysAddr] = peripheral.readsHaveSideEffects ? 0 : 1
        return true
    }

    func claimWrite(sysAddr: Int, peripheral: Peripheral, periphAddr: Int) -> Bool {
        guard sysAddr < memorySize else { return false }
        ensureShadowAllocated()
        memorySpaceWrite[sysAddr].updateMap(who: peripheral, addr: periphAddr, waitStates: nil)
        memorySpaceWriteShadow?[sysAddr] = peripheral.writesAreMemoryBacked ? 1 : 0
        return true
    }

    func claimIORead(sysAddr: Int, peripheral: Peripheral, periphAddr: Int) -> Bool {
        guard sysAddr < ioSize else { return false }
        ioSpaceRead[sysAddr].updateMap(who: peripheral, addr: periphAddr, waitStates: nil)
        return true
    }

    func claimIOWrite(sysAddr: Int, peripheral: Peripheral, periphAddr: Int) -> Bool {
        guard sysAddr < ioSize else { return false }
        ioSpaceWrite[sysAddr].updateMap(who: peripheral, addr: periphAddr, waitStates: nil)
        return true
    }

    // MARK: - Memory Access

    func readMemoryByte(address: Int, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        var addr = address
        if addr >= memorySize { addr &= (memorySize - 1) }
        if let tracker = accessTracker, accessType != .free {
            tracker.recordRead(address: addr)
        }
        cycles += memorySpaceRead[addr].waitStates
        // Fast path: ~99% of memory is RAM/ROM/Cart and served from shadow.
        if memorySpaceReadFast.unsafelyUnwrapped[addr] != 0 {
            return shadowMemory.unsafelyUnwrapped[addr]
        }
        return memorySpaceRead[addr].who.read(
            addr: memorySpaceRead[addr].addr, isIO: false, cycles: &cycles, accessType: accessType)
    }

    /// Side-effect-free memory read using peek().
    /// Used by the CPU for the "companion" byte in a word access — the TMS9900
    /// performs a single word bus cycle, so the peripheral should see only one
    /// access.  The companion byte is read via peek() to avoid triggering
    /// hardware side-effects (e.g. GROM prefetch advance).
    func peekMemoryByte(address: Int) -> UInt8 {
        var addr = address
        if addr >= memorySize { addr &= (memorySize - 1) }
        if memorySpaceReadFast.unsafelyUnwrapped[addr] != 0 {
            return shadowMemory.unsafelyUnwrapped[addr]
        }
        return memorySpaceRead[addr].who.peek(addr: memorySpaceRead[addr].addr)
    }

    /// Diagnostic-only: read from the peripheral directly, bypassing the
    /// shadow fast-path. Use this to detect stale-shadow bugs by comparing
    /// against `peekMemoryByte` at the same address.
    func peekMemoryByteFromPeripheral(address: Int) -> UInt8 {
        var addr = address
        if addr >= memorySize { addr &= (memorySize - 1) }
        return memorySpaceRead[addr].who.peek(addr: memorySpaceRead[addr].addr)
    }

    func writeMemoryByte(address: Int, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        var addr = address
        if addr >= memorySize { addr &= (memorySize - 1) }
        if let tracker = accessTracker, accessType != .free {
            tracker.recordWrite(address: addr)
        }
        cycles += memorySpaceRead[addr].waitStates
        memorySpaceWrite[addr].who.write(
            addr: memorySpaceWrite[addr].addr, isIO: false, cycles: &cycles, accessType: accessType, data: data)
        // Only mirror into shadow when the peripheral is actually memory-backed
        // (i.e. RAM). Mirroring writes to ROM/sound/VDP would taint the read
        // fast path with values that don't reflect what hardware returns.
        let shadowFlag = memorySpaceWriteShadow.unsafelyUnwrapped[addr]
        if shadowFlag != 0 {
            shadowMemory.unsafelyUnwrapped[addr] = data
        }
    }

    /// Re-peek every byte in `[sysAddr, sysAddr+length)` to refresh the
    /// shadow. Called by peripherals whose `read()` value changes out of
    /// band — most notably bank-switched cartridges, where a write triggers
    /// a bank flip and now the same CPU addresses return different bytes.
    func refreshShadowRange(sysAddr: Int, length: Int) {
        guard let shadow = shadowMemory else { return }
        let end = min(sysAddr + length, memorySize)
        guard sysAddr >= 0 && sysAddr < memorySize else { return }
        for a in sysAddr..<end {
            let entry = memorySpaceRead[a]
            shadow[a] = entry.who.peek(addr: entry.addr)
        }
    }

    /// Update a single byte of the shadow. Used by peripherals that own
    /// memory-backed regions (e.g. MBX cartridge RAM) but whose `claimWrite`
    /// is registered with `writesAreMemoryBacked = false` because most of
    /// the address space is *not* memory-backed (banked ROM).
    func updateShadowByte(sysAddr: Int, data: UInt8) {
        guard let shadow = shadowMemory, sysAddr >= 0 && sysAddr < memorySize else { return }
        shadow[sysAddr] = data
    }

    func readIOByte(address: Int, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        var addr = address
        if addr >= ioSize { addr &= (ioSize - 1) }
        cycles += ioSpaceRead[addr].waitStates
        return ioSpaceRead[addr].who.read(
            addr: ioSpaceRead[addr].addr, isIO: true, cycles: &cycles, accessType: accessType)
    }

    func writeIOByte(address: Int, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        var addr = address
        if addr >= ioSize { addr &= (ioSize - 1) }
        cycles += ioSpaceRead[addr].waitStates
        ioSpaceWrite[addr].who.write(
            addr: ioSpaceWrite[addr].addr, isIO: true, cycles: &cycles, accessType: accessType, data: data)
    }

    // MARK: - Hold/Halt

    func requestHold(device: Int) {
        hold |= (1 << UInt32(device))
    }

    func getHoldStatus(device: Int) -> Bool {
        if device == -1 { return hold != 0 }
        return (hold & (1 << UInt32(device))) != 0
    }

    func releaseHold(device: Int) {
        hold &= ~(1 << UInt32(device))
    }

    // MARK: - Interrupts

    func requestInt(level: Int) {
        intReqLevel |= (1 << UInt32(level))
    }

    func clearInt(level: Int) {
        intReqLevel &= ~(1 << UInt32(level))
    }

    func requestNMI() { nmiReq = true }
    func clearNMI() { nmiReq = false }

    /// Optional hook invoked at every CPU interrupt-pending check.
    /// Lets the TMS9901 refresh its timer state (and therefore the level-1
    /// request line) using the CPU's fine-grained cycle count, rather than
    /// only at emulator-slice boundaries. Without this, a TMS9901 timer
    /// loaded with a small value (e.g. 1 tick = 21 µs, which the cassette
    /// ROM does for FSK oversampling) only fires once per millisecond
    /// instead of ~47 times per millisecond.
    var preInterruptCheck: (() -> Void)?

    func interruptPending() -> Bool {
        preInterruptCheck?()
        return intReqLevel != 0 || nmiReq
    }

    func getIntLevels() -> UInt32 { return intReqLevel }
    func getNMI() -> Bool { return nmiReq }

    // MARK: - PC Interception

    /// Handlers called when the CPU reaches specific addresses.
    /// Key = PC address, Value = handler that returns true if the interception was handled
    /// (and CPU should NOT execute the instruction at that address).
    var pcInterceptors: [UInt16: (TMS9900) -> Bool] = [:]

    /// Check if there's an interceptor for the current PC address
    func checkPCIntercept(cpu: TMS9900) -> Bool {
        if let handler = pcInterceptors[cpu.PC] {
            return handler(cpu)
        }
        return false
    }

    // MARK: - Debug Memory Snapshot

    /// Copy the current visualization-shadow memory into `dest` via a single
    /// `memcpy` of `memorySize` bytes. Replaces the per-byte virtual `peek()`
    /// loop, dropping snapshot cost from ~13 ms to ~10 µs at 64KB.
    func snapshotMemoryInto(_ dest: UnsafeMutableRawPointer) {
        if let shadow = shadowMemory, memorySize > 0 {
            memcpy(dest, shadow, memorySize)
        } else {
            memset(dest, 0, memorySize)
        }
    }

    // MARK: - Breakpoints (stub)

    func triggerBreakpoint() {}
    func processDebug() {}
}
