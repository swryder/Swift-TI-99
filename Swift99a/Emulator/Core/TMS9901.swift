// Swift 99/a
//
// TMS9901 Programmable Systems Interface
// Handles interrupt inputs, timer, and I/O for the TI-99/4A.
// Currently implements the minimum needed for correct VDP interrupt handling:
//   - CRU bit 0: Clock mode control
//   - CRU bit 1: External interrupt input (active low, directly on pin)
//   - CRU bit 2: VDP interrupt input (directly reflects VDP INT* status)
//   - CRU bit 3-14: I/O pins / timer (delegated to keyboard for bits 3-10)
//   - CRU bit 15+: I/O pins (handled by keyboard peripheral)
//
// On the real TMS9901:
//   SBO n (n=1..15 in I/O mode): Enables interrupt level n
//   SBZ n (n=1..15 in I/O mode): Disables interrupt level n
//   TB n: Reads the RAW pin level (not masked, not inverted)
//
// The VDP INT* line connects to INT1 (CRU bit 2) and is active LOW.
// TB 2 returns 0 when VDP interrupt is active (pin driven low by VDP),
// and returns 1 when no interrupt (pin high). When the VDP status
// register is read, the VDP clears its INT flag and releases the pin.

import Foundation

final class TMS9901: Peripheral {
    // Reference to the VDP for checking interrupt status
    weak var vdp: TMS9918?

    // Clock/timer mode flag (bit 0 write)
    private var clockMode: Bool = false

    // Interrupt mask bits (bits 1-15): true = masked (disabled)
    private var intMask: UInt16 = 0

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TMS9901", index: index)
        return true
    }

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        // addr is the CRU bit number (0-31)
        switch addr {
        case 0:
            // Bit 0: clock mode status
            return clockMode ? 1 : 0

        case 1:
            // Bit 1: peripheral interrupt (directly reflects pin state)
            // On TI-99/4A this is typically unused / active
            return 0

        case 2:
            // Bit 2: VDP interrupt input (INT1)
            // On real hardware, TB reads the RAW pin level (active LOW):
            //   Pin LOW  (interrupt active)   → TB returns 0
            //   Pin HIGH (no interrupt)       → TB returns 1
            //
            // However, because the emulator batches thousands of CPU cycles
            // per runSystem() tick, a VDP status read (which clears the
            // INT flag) can happen in the SAME batch as the NEXT ISR entry.
            // The second ISR then sees the pin HIGH and takes the peripheral-
            // scan path, which skips the user ISR hook at >83C4.
            //
            // Extended Basic (and other software) installs a user ISR hook
            // for speech FIFO feeding, sprite motion, etc.  Skipping it
            // causes hangs.
            //
            // On real hardware the level-1 interrupt fires ONLY when the
            // VDP INT* pin is active, so the ISR always sees pin LOW when
            // it checks TB 2.  We emulate that guarantee by always
            // returning 0 (pin LOW / interrupt active).
            return 0

        default:
            // Bits 3+: keyboard and other I/O — handled by keyboard peripheral
            return 0
        }
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        switch addr {
        case 0:
            // Bit 0: enter/exit clock mode
            clockMode = (data != 0)

        case 1...15:
            // In clock mode (bit 0 = 1): write to timer
            // In I/O mode (bit 0 = 0): set interrupt mask
            if !clockMode {
                if data != 0 {
                    // SBO: mask (disable) this interrupt
                    intMask |= (1 << UInt16(addr))
                } else {
                    // SBZ: unmask (enable) this interrupt
                    intMask &= ~(1 << UInt16(addr))
                }
            }

        default:
            // Bits 16+: I/O pins handled by keyboard peripheral
            break
        }
    }
}
