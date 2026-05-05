// Swift 99/a
//
// TMS9900.swift
// Emulation of the Texas Instruments TMS9900 16-bit CPU.
//
// Key characteristics of the real TMS9900:
//   - 16-bit data bus, 16-bit address bus (64 KB addressable)
//   - All memory accesses are word-aligned (even addresses only)
//   - Registers R0–R15 live in external RAM, selected by the Workspace
//     Pointer (WP). Context switches simply change WP — no register
//     save/restore overhead.
//   - Status register (ST) with Logical/Arithmetic Greater Than, Equal,
//     Carry, Overflow, Odd Parity, and XOP bits, plus 4-bit interrupt mask.
//   - CRU (Communication Register Unit) for bit-addressable I/O.
//   - The CPU clock here runs at 3 MHz (TI-99/4A standard).
//
// Implementation notes:
//   - operate() converts microseconds → cycles (×3 for 3 MHz) and runs
//     the fetch-decode-execute loop until the cycle budget is consumed.
//   - Addressing modes 0–3 (register, indirect, symbolic/indexed,
//     auto-increment) are resolved by fixS()/fixD().
//   - Word reads use romword() which calls read() on the even byte and
//     peek() on the odd byte to avoid double side-effects on peripherals
//     like GROM that auto-increment on access.

import Foundation

// MARK: - Status Register Bit Constants
let BIT_LGT: UInt16 = 0x8000
let BIT_AGT: UInt16 = 0x4000
let BIT_EQ:  UInt16 = 0x2000
let BIT_C:   UInt16 = 0x1000
let BIT_OV:  UInt16 = 0x0800
let BIT_OP:  UInt16 = 0x0400
let BIT_XOP: UInt16 = 0x0200

let MASK_LGT_AGT_EQ:       UInt16 = BIT_LGT | BIT_AGT | BIT_EQ
let MASK_LGT_AGT_EQ_OP:    UInt16 = BIT_LGT | BIT_AGT | BIT_EQ | BIT_OP
let MASK_LGT_AGT_EQ_OV:    UInt16 = BIT_LGT | BIT_AGT | BIT_EQ | BIT_OV
let MASK_LGT_AGT_EQ_OV_C:  UInt16 = BIT_LGT | BIT_AGT | BIT_EQ | BIT_OV | BIT_C

final class TMS9900: Peripheral {

    // MARK: - CPU Registers
    var PC: UInt16 = 0   // Program Counter (always even-aligned)
    var WP: UInt16 = 0   // Workspace Pointer — base address of R0–R15 in external RAM
    var ST: UInt16 = 0   // Status Register (bits 0–6: flags, bits 12–15: interrupt mask)

    // MARK: - Opcode Decoding Fields (set during instruction decode)
    var currentOp: UInt16 = 0  // Raw opcode word
    var D: UInt16 = 0          // Destination operand / register number
    var S: UInt16 = 0          // Source operand / register number
    var Td: UInt16 = 0         // Destination addressing mode (0–3)
    var Ts: UInt16 = 0         // Source addressing mode (0–3)
    var B: UInt16 = 0          // Byte operation flag (1 = byte, 0 = word)

    var X_flag: UInt16 = 0         // Non-zero during X (execute) instruction — holds return PC
    var nCycleCount: Int = 0       // Cycles consumed by the current instruction
    var idling: Bool = false       // True when IDLE instruction is active (waiting for interrupt)
    var nReturnAddress: UInt16 = 0 // Saved return address for BL/BLWP tracking
    var skip_interrupt: Int = 0    // Countdown: skip interrupt checks after context switch

    /// Running total of CPU cycles consumed (for MHz calculation)
    var totalCycleCount: Int = 0

    /// TEMP debug counter for the cassette ISR's wait-loop compare.
    static var cDebugLogCount: Int = 0

    // Pre-computed status flag lookup tables. These avoid repeated branching
    // in the hot path by mapping a result value directly to its status flags.
    // wStatusLookup: indexed by 16-bit word result (65536 entries)
    // bStatusLookup: indexed by 8-bit byte result (256 entries), includes parity
    static let wStatusLookup: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65536)
        for i in 0..<65536 {
            var v: UInt16 = 0
            if i > 0 { v |= BIT_LGT }
            if i > 0 && i < 0x8000 { v |= BIT_AGT }
            if i == 0 { v |= BIT_EQ; v |= BIT_C }
            if i == 0x8000 { v |= BIT_OV }
            table[i] = v
        }
        return table
    }()

    static let bStatusLookup: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var v: UInt16 = 0
            if i > 0 { v |= BIT_LGT }
            if i > 0 && i < 0x80 { v |= BIT_AGT }
            if i == 0 { v |= BIT_EQ; v |= BIT_C }
            if i == 0x80 { v |= BIT_OV }
            // parity
            var x = UInt8(i & 0xFF)
            var z = 0
            while x != 0 { z += 1; x &= (x &- 1) }
            if z & 1 != 0 { v |= BIT_OP }
            table[i] = v
        }
        return table
    }()

    // MARK: - Init

    /// Direct unowned reference to the owning core. The base class's
    /// `theCore` is `weak`, which costs a runtime atomic-load on every memory
    /// access. The CPU hot path (`romword`, `wrword`, etc.) calls into the
    /// core 4-8× per instruction, so we keep a separate `unowned` reference
    /// that compiles to a plain pointer load. Safe because the CPU is owned
    /// by `EmulatorSystem` (via `TI994A`) and cannot outlive it.
    unowned let core: EmulatorSystem

    init(core: EmulatorSystem) {
        self.core = core
        super.init(core: core)
    }

    // MARK: - Peripheral Lifecycle

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TMS9900", index: index)
        reset()
        return true
    }

    override func cleanup() -> Bool {
        return true
    }

    override func operate(timestamp: Double) -> Bool {
        // timestamp is in microseconds, CPU runs at 3MHz
        let scaledTimestamp = timestamp * 3.0

        if lastTimestamp == 0 || scaledTimestamp < lastTimestamp {
            lastTimestamp = scaledTimestamp
            return true
        }

        // stopped?
        if core.getHoldStatus(device: -1) {
            lastTimestamp = scaledTimestamp
            return true
        }

        // idling?
        if !core.interruptPending() && idling {
            lastTimestamp = scaledTimestamp
            return true
        }

        // run cycles
        nCycleCount = 0
        while lastTimestamp < scaledTimestamp {
            nCycleCount = 0

            // check interrupts
            if skip_interrupt > 0 {
                skip_interrupt -= 1
            } else {
                if core.interruptPending() {
                    if core.getNMI() {
                        triggerInterrupt(level: -1)
                        continue
                    } else {
                        // Per TMS9900 spec, the ST mask is the *highest* level
                        // accepted — interrupts fire when level <= mask. The
                        // previous `0..<minLevel` excluded the boundary, so e.g.
                        // LIMI #1 only allowed level 0; the VDP's level-1
                        // interrupt was permanently masked. The cassette ROM
                        // loop at >1574 waits for the level-1 ISR (which calls
                        // the cassette decoder at >1404), so this off-by-one
                        // froze the read entirely.
                        let mask = Int(ST & 0x000F)
                        let ints = core.getIntLevels()
                        var triggered = false
                        for idx in 0...mask {
                            if ints & (1 << UInt32(idx)) != 0 {
                                triggerInterrupt(level: idx)
                                triggered = true
                                break
                            }
                        }
                        if triggered { continue }
                    }
                }
            }

            // Check for PC interception (DSR entry points, etc.)
            if core.checkPCIntercept(cpu: self) {
                addCycles(20)  // Account for intercepted operation time
                continue
            }

            // [trace] log instruction PC visits inside cassette code
            // (>1400-15FF) so we can see exactly which spin-loop branch
            // the ROM is in and how long it spends in each.
            CassetteTrace.logPC(currentCycle: totalCycleCount, pc: PC)

            // [trace] byte-assembly + post-mark register-dump hooks.
            // PC=0x15B6 = end of bit-read loop, R4 holds the assembled
            // byte. PC=0x14DA/14DE/14E0/14E2/1562 = post-byte state-
            // machine checkpoints where the cassette ROM compares R5
            // vs R1 (the mark byte check). Dumping all the workspace
            // registers gives us a side-by-side view against Classic99.
            if CassetteTrace.motorActive {
                let pc = PC
                if pc == 0x15B6 || pc == 0x14DA || pc == 0x14DE ||
                   pc == 0x14E0 || pc == 0x14E2 || pc == 0x1562 {
                    let wp = Int(WP)
                    func r(_ n: Int) -> UInt16 {
                        let addr = wp + n * 2
                        let hi = core.peekMemoryByte(address: addr)
                        let lo = core.peekMemoryByte(address: addr + 1)
                        return (UInt16(hi) << 8) | UInt16(lo)
                    }
                    func rPeriph(_ n: Int) -> UInt16 {
                        let addr = wp + n * 2
                        let hi = core.peekMemoryByteFromPeripheral(address: addr)
                        let lo = core.peekMemoryByteFromPeripheral(address: addr + 1)
                        return (UInt16(hi) << 8) | UInt16(lo)
                    }
                    if pc == 0x15B6 {
                        CassetteTrace.log(currentCycle: totalCycleCount,
                                          event: "BYTE",
                                          details: String(format: "r4=%04X r7=%04X", r(4), r(7)))
                    } else {
                        // R5 logged twice: shadow (what CPU normally reads) vs
                        // peripheral (raw RAM). If they differ, shadow is stale.
                        CassetteTrace.log(currentCycle: totalCycleCount,
                                          event: "PCREGS",
                                          details: String(format:
                                            "pc=%04X wp=%04X r0=%04X r1=%04X r2=%04X r3=%04X r4=%04X r5=%04X r5p=%04X r6=%04X r7=%04X r8=%04X r9=%04X r10=%04X",
                                            pc, UInt16(wp), r(0), r(1), r(2), r(3), r(4), r(5), rPeriph(5), r(6), r(7), r(8), r(9), r(10)))
                    }
                }
            }

            // fetch and execute
            currentOp = romword(S: PC)
            addPC(2)
            executeOpcode(currentOp)

            totalCycleCount += nCycleCount
            lastTimestamp += Double(nCycleCount)
        }

        return true
    }

    // MARK: - Reset

    func reset() {
        idling = false
        nReturnAddress = 0
        triggerInterrupt(level: 0)
        addCycles(4)
        X_flag = 0
        ST &= 0xFFF0
    }

    // MARK: - Memory Access Wrappers

    func rcpubyte(_ src: UInt16) -> UInt8 {
        // The TMS9900 performs a word-aligned bus cycle, but only ONE
        // peripheral interaction occurs.  To avoid double side-effects
        // (e.g. GROM prefetch advance), we use a full read() only for
        // the byte the CPU actually wants, and peek() for the companion.
        if (src & 1) != 0 {
            // Target is the odd (LSB) byte — read it with side effects,
            // peek the even byte as a passive companion.
            let lsb = core.readMemoryByte(address: Int(src), cycles: &nCycleCount, accessType: .read)
            return lsb
        } else {
            // Target is the even (MSB) byte — read it with side effects,
            // peek the odd byte as a passive companion.
            let msb = core.readMemoryByte(address: Int(src), cycles: &nCycleCount, accessType: .read)
            return msb
        }
    }

    func wcpubyte(_ dest: UInt16, _ c: UInt8) {
        // Read-before-write: same word-aligned access rule applies.
        let adr = Int(dest & 0xFFFE)
        let lsb = core.peekMemoryByte(address: adr + 1)
        let msb = core.readMemoryByte(address: adr, cycles: &nCycleCount, accessType: .rmw)

        if dest & 1 != 0 {
            core.writeMemoryByte(address: adr + 1, cycles: &nCycleCount, accessType: .write, data: c)
            core.writeMemoryByte(address: adr, cycles: &nCycleCount, accessType: .write, data: msb)
            CassetteTrace.logMemWrite(currentCycle: totalCycleCount, address: adr + 1, data: c, pc: PC)
        } else {
            core.writeMemoryByte(address: adr + 1, cycles: &nCycleCount, accessType: .write, data: lsb)
            core.writeMemoryByte(address: adr, cycles: &nCycleCount, accessType: .write, data: c)
            CassetteTrace.logMemWrite(currentCycle: totalCycleCount, address: adr, data: c, pc: PC)
        }
    }

    func romword(S src: UInt16, rmw: MemoryAccess = .read) -> UInt16 {
        // Word read: even-address byte triggers side-effects,
        // odd-address byte is a passive companion read (peek).
        let lsb = core.peekMemoryByte(address: Int(src | 1))
        let msb = core.readMemoryByte(address: Int(src & 0xFFFE), cycles: &nCycleCount, accessType: rmw)
        return (UInt16(msb) << 8) | UInt16(lsb)
    }

    func wrword(D dest: UInt16, V val: UInt16, rmw: MemoryAccess = .write) {
        let d = Int(dest & 0xFFFE)
        let lo = UInt8(val & 0xFF)
        let hi = UInt8((val >> 8) & 0xFF)
        core.writeMemoryByte(address: d + 1, cycles: &nCycleCount, accessType: rmw, data: lo)
        core.writeMemoryByte(address: d, cycles: &nCycleCount, accessType: rmw, data: hi)
        // [trace] log word writes inside scratchpad as a pair of bytes
        CassetteTrace.logMemWrite(currentCycle: totalCycleCount, address: d, data: hi, pc: PC)
        CassetteTrace.logMemWrite(currentCycle: totalCycleCount, address: d + 1, data: lo, pc: PC)
    }

    // MARK: - PC/WP/ST Helpers

    func addPC(_ x: Int) {
        PC = (PC &+ UInt16(truncatingIfNeeded: x)) & 0xFFFE
    }

    func setPC(_ x: UInt16) {
        PC = x & 0xFFFE
    }

    func setWP(_ x: UInt16) {
        WP = x & 0xFFFE
    }

    func setST(_ x: UInt16) {
        ST = x
    }

    func addCycles(_ val: Int) {
        nCycleCount += val
    }

    // MARK: - Interrupt Handling

    func triggerInterrupt(level: Int) {
        let vector = UInt16(level * 4)

        // [trace] INT1ENTRY — capture interrupted PC/WP/ST plus full
        // R0-R15 of the interrupted workspace so we can see exactly
        // what the cassette ROM's state was when the timer fired.
        if level == 1 {
            CassetteTrace.log(currentCycle: totalCycleCount,
                              event: "INT1ENTRY",
                              details: String(format: "pc=%04X wp=%04X st=%04X src=?",
                                              PC, WP, ST))
            // Read 16 registers of the WP being interrupted.
            var regs = [UInt16](); regs.reserveCapacity(16)
            for i in 0..<16 {
                let addr = Int(WP) + i * 2
                let hi = core.peekMemoryByte(address: addr)
                let lo = core.peekMemoryByte(address: addr + 1)
                regs.append((UInt16(hi) << 8) | UInt16(lo))
            }
            CassetteTrace.logRegs(currentCycle: totalCycleCount,
                                  label: "at=int1", regs: regs)
        }

        idling = false

        let newWP = romword(S: vector)
        wrword(D: newWP &+ 26, V: WP)
        wrword(D: newWP &+ 28, V: PC)
        wrword(D: newWP &+ 30, V: ST)

        // Per TMS9900 datasheet: new ST.LIMI = level - 1 (so a level-N
        // interrupt masks levels N and higher). For level-1, LIMI=0.
        // (Tried LIMI=1 to match Classic99 v1's quirk where it passes
        //  `level=2` to TriggerInterrupt — turned out to be a no-op for
        //  the cassette decode because the ISR's first instruction at
        //  >0900 is `LIMI 0`, which immediately overrides whatever
        //  triggerInterrupt set.)
        if level <= 0 {
            setST(ST & 0xFFF0)
        } else {
            setST((ST & 0xFFF0) | UInt16(level - 1))
        }

        let newPC = romword(S: vector &+ 2)
        setWP(newWP)
        setPC(newPC)

        addCycles(22)
        skip_interrupt = 2
    }

    // MARK: - Addressing Modes
    // Resolve the source/destination operand address based on mode (Ts/Td):
    //   Mode 0: Register direct         — Rn             (address = WP + 2*n)
    //   Mode 1: Register indirect       — *Rn            (address = contents of Rn)
    //   Mode 2: Symbolic/Indexed        — @addr or @addr(Rn) (address = immediate ± Rn)
    //   Mode 3: Auto-increment indirect — *Rn+           (address = contents of Rn, then Rn += 1 or 2)

    /// Resolve source operand address into S based on addressing mode Ts.
    func fixS() {
        switch Ts {
        case 0:  // Register direct: S = address of register
            S = WP &+ (S << 1)

        case 1:  // Register indirect: S = contents of register (a pointer)
            S = romword(S: WP &+ (S << 1))
            addCycles(4)

        case 2:  // Symbolic (R0) or Indexed (Rn): S = immediate word [+ Rn]
            if S != 0 {
                S = romword(S: PC) &+ romword(S: WP &+ (S << 1))
            } else {
                S = romword(S: PC)
            }
            addPC(2)
            addCycles(8)

        case 3:  // Auto-increment: S = contents of register, then register += 1 (byte) or 2 (word)
            let t2 = WP &+ (S << 1)
            let temp = romword(S: t2)
            S = temp
            wrword(D: t2, V: temp &+ (B == 1 ? 1 : 2))
            addCycles(B == 1 ? 6 : 8)

        default:
            break
        }
    }

    /// Resolve destination operand address into D based on addressing mode Td.
    func fixD() {
        switch Td {
        case 0:
            D = WP &+ (D << 1)

        case 1:
            D = romword(S: WP &+ (D << 1))
            addCycles(4)

        case 2:
            if D != 0 {
                D = romword(S: PC) &+ romword(S: WP &+ (D << 1))
            } else {
                D = romword(S: PC)
            }
            addPC(2)
            addCycles(8)

        case 3:
            let t2 = WP &+ (D << 1)
            let temp = romword(S: t2)
            D = temp
            wrword(D: t2, V: temp &+ (B == 1 ? 1 : 2))
            addCycles(B == 1 ? 6 : 8)

        default:
            break
        }
    }

    // MARK: - Status Helpers

    func resetST(_ bits: UInt16) { ST &= ~bits }
    func setST(bits: UInt16) { ST |= bits }

    var ST_LGT: Bool { ST & BIT_LGT != 0 }
    var ST_AGT: Bool { ST & BIT_AGT != 0 }
    var ST_EQ:  Bool { ST & BIT_EQ  != 0 }
    var ST_C:   Bool { ST & BIT_C   != 0 }
    var ST_OV:  Bool { ST & BIT_OV  != 0 }
    var ST_OP:  Bool { ST & BIT_OP  != 0 }

    // MARK: - Opcode Dispatch

    func executeOpcode(_ op: UInt16) {
        let top4 = (op >> 12) & 0xF

        switch top4 {
        case 0:  executeOpcode0(op)
        case 1:  executeOpcode1(op)
        case 2:  executeOpcode2(op)
        case 3:  executeOpcode3(op)
        case 4:  op_szc()
        case 5:  op_szcb()
        case 6:  op_s()
        case 7:  op_sb()
        case 8:  op_c()
        case 9:  op_cb()
        case 10: op_a()
        case 11: op_ab()
        case 12: op_mov()
        case 13: op_movb()
        case 14: op_soc()
        case 15: op_socb()
        default: op_bad()
        }
    }

    private func executeOpcode0(_ op: UInt16) {
        let x = (op >> 8) & 0xF
        switch x {
        case 2:  executeOpcode02(op)
        case 3:  executeOpcode03(op)
        case 4:  executeOpcode04(op)
        case 5:  executeOpcode05(op)
        case 6:  executeOpcode06(op)
        case 7:  executeOpcode07(op)
        case 8:  op_sra()
        case 9:  op_srl()
        case 10: op_sla()
        case 11: op_src()
        default: op_bad()
        }
    }

    private func executeOpcode02(_ op: UInt16) {
        let x = (op >> 4) & 0xE
        switch x {
        case 0:  op_li()
        case 2:  op_ai()
        case 4:  op_andi()
        case 6:  op_ori()
        case 8:  op_ci()
        case 10: op_stwp()
        case 12: op_stst()
        case 14: op_lwpi()
        default: op_bad()
        }
    }

    private func executeOpcode03(_ op: UInt16) {
        let x = (op >> 4) & 0xE
        switch x {
        case 0:  op_limi()
        case 4:  op_idle()
        case 6:  op_rset()
        case 8:  op_rtwp()
        case 10: op_ckon()
        case 12: op_ckof()
        case 14: op_lrex()
        default: op_bad()
        }
    }

    private func executeOpcode04(_ op: UInt16) {
        let x = (op >> 4) & 0xC
        switch x {
        case 0:  op_blwp()
        case 4:  op_b()
        case 8:  op_x()
        case 12: op_clr()
        default: op_bad()
        }
    }

    private func executeOpcode05(_ op: UInt16) {
        let x = (op >> 4) & 0xC
        switch x {
        case 0:  op_neg()
        case 4:  op_inv()
        case 8:  op_inc()
        case 12: op_inct()
        default: op_bad()
        }
    }

    private func executeOpcode06(_ op: UInt16) {
        let x = (op >> 4) & 0xC
        switch x {
        case 0:  op_dec()
        case 4:  op_dect()
        case 8:  op_bl()
        case 12: op_swpb()
        default: op_bad()
        }
    }

    private func executeOpcode07(_ op: UInt16) {
        let x = (op >> 4) & 0xC
        switch x {
        case 0:  op_seto()
        case 4:  op_abs()
        default: op_bad()
        }
    }

    private func executeOpcode1(_ op: UInt16) {
        let x = (op >> 8) & 0xF
        switch x {
        case 0:  op_jmp()
        case 1:  op_jlt()
        case 2:  op_jle()
        case 3:  op_jeq()
        case 4:  op_jhe()
        case 5:  op_jgt()
        case 6:  op_jne()
        case 7:  op_jnc()
        case 8:  op_joc()
        case 9:  op_jno()
        case 10: op_jl()
        case 11: op_jh()
        case 12: op_jop()
        case 13: op_sbo()
        case 14: op_sbz()
        case 15: op_tb()
        default: op_bad()
        }
    }

    private func executeOpcode2(_ op: UInt16) {
        let x = (op >> 8) & 0xC
        switch x {
        case 0:  op_coc()
        case 4:  op_czc()
        case 8:  op_xor()
        case 12: op_xop()
        default: op_bad()
        }
    }

    private func executeOpcode3(_ op: UInt16) {
        let x = (op >> 8) & 0xC
        switch x {
        case 0:  op_ldcr()
        case 4:  op_stcr()
        case 8:  op_mpy()
        case 12: op_div()
        default: op_bad()
        }
    }
}
