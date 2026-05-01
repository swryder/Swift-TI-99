// Swift 99/a
//
// MemoryAccess.swift
// Classifies bus transactions so peripherals can distinguish real CPU
// accesses from internal housekeeping (e.g. prefetch, debug reads).

import Foundation

/// Classifies bus transactions for cycle counting and breakpoint behavior.
enum MemoryAccess {
    /// Normal read cycle — counts wait states and triggers read breakpoints.
    case read
    /// Normal write cycle — counts wait states and triggers write breakpoints.
    case write
    /// Read-before-write (e.g. byte ops on word bus) — counts cycles but no breakpoint.
    case rmw
    /// Internal access (debug, peek, prefetch) — no cycle cost, no breakpoint.
    case free
}
