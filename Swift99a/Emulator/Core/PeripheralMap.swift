// Swift 99/a
//
// PeripheralMap.swift
// Per-byte mapping entry that associates an address in the CPU memory space
// (or CRU I/O space) with a specific Peripheral and its local address offset.
// EmulatorSystem maintains four arrays of these: memorySpaceRead/Write and
// ioSpaceRead/Write, enabling separate read and write routing per byte.

import Foundation

/// Per-byte mapping entry linking a system address to a Peripheral + local address.
struct PeripheralMap {
    var who: Peripheral
    var addr: Int
    var waitStates: Int

    init() {
        self.who = DummyPeripheral.shared
        self.addr = 0
        self.waitStates = 0
    }

    init(who: Peripheral, addr: Int, waitStates: Int) {
        self.who = who
        self.addr = addr
        self.waitStates = waitStates
    }

    /// Pass nil or -1 to leave unchanged
    mutating func updateMap(who: Peripheral?, addr: Int?, waitStates: Int?) {
        if let who = who { self.who = who }
        if let addr = addr, addr != -1 { self.addr = addr }
        if let waitStates = waitStates, waitStates != -1 { self.waitStates = waitStates }
    }
}
