// Swift 99/a
//
// TMS9900+Opcodes.swift
// All TMS9900 opcode implementations, organized by category:
//   - Format Helpers: Instruction field decoding and jump logic
//   - Arithmetic:  A, AB, ABS, AI, DEC, DECT, DIV, INC, INCT, MPY, NEG, S, SB
//   - Branch:      B, BL, BLWP, RTWP, X, XOP
//   - Jump:        JEQ, JGT, JHE, JH, JL, JLE, JLT, JMP, JNC, JNE, JNO, JOP, JOC
//   - Compare:     C, CB, CI, COC, CZC
//   - CRU:         LDCR, SBO, SBZ, STCR, TB
//   - Load/Store:  LI, LIMI, LWPI, MOV, MOVB, STST, STWP, SWPB
//   - Logic:       ANDI, ORI, XOR, INV, CLR, SETO, SOC, SOCB, SZC, SZCB
//   - Shift:       SRA, SRL, SLA, SRC
//   - Special:     IDLE, RSET, CKOF, CKON, LREX, bad (illegal opcode)

import Foundation

// MARK: - Format Helpers (instruction field decoding)
extension TMS9900 {

    /// Decode Format I instruction fields (two-operand: A, S, MOV, etc.)
    /// Bit layout: [opcode:4][B:1][D:4][Td:2][S:4][Ts:2]  (low 13 bits)
    func decodeFormatI() {
        Td = (currentOp & 0x0C00) >> 10
        Ts = (currentOp & 0x0030) >> 4
        D  = (currentOp & 0x03C0) >> 6
        S  = (currentOp & 0x000F)
        B  = (currentOp & 0x1000) >> 12
    }

    /// Decode Format VI instruction fields (single-operand: B, BL, CLR, INC, etc.)
    /// Bit layout: [opcode:10][Ts:2][S:4]
    func decodeFormatVI() {
        Ts = (currentOp & 0x0030) >> 4
        S  = currentOp & 0x000F
        B  = 0
    }

    /// Decode Format IX instruction fields (MPY, DIV, XOP)
    /// Bit layout: [opcode:6][D:4][Ts:2][S:4]
    func decodeFormatIX() {
        D  = (currentOp & 0x03C0) >> 6
        Ts = (currentOp & 0x0030) >> 4
        S  = currentOp & 0x000F
        B  = 0
    }

    /// Execute a conditional jump. The displacement is a signed 8-bit offset
    /// in words from the current PC. Costs 10 cycles if taken, 8 if not.
    func doJump(_ condition: Bool) {
        var disp = currentOp & 0x00FF

        if condition {
            if X_flag != 0 {
                setPC(X_flag)
            }
            if disp & 0x80 != 0 {
                disp = 128 - (disp & 0x7F)
                addPC(-Int(disp &+ disp))
            } else {
                addPC(Int(disp &+ disp))
            }
            addCycles(10)
        } else {
            addCycles(8)
        }
    }
}

// MARK: - Arithmetic Operations
extension TMS9900 {

    func op_a() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x1 &+ x2
        wrword(D: D, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 < x2 { setST(bits: BIT_C) }
        if (x1 & 0x8000) == (x2 & 0x8000) && (x3 & 0x8000) != (x2 & 0x8000) { setST(bits: BIT_OV) }
    }

    func op_ab() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let x2: UInt16
        let resultByte: UInt16
        let newXD: UInt16

        if D & 1 != 0 {
            x2 = xD & 0xFF
            resultByte = (x2 &+ x1) & 0xFF
            newXD = (xD & 0xFF00) | resultByte
        } else {
            x2 = xD >> 8
            resultByte = (x2 &+ x1) & 0xFF
            newXD = (xD & 0x00FF) | (resultByte << 8)
        }
        wrword(D: D, V: newXD)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV | BIT_OP)
        ST |= TMS9900.bStatusLookup[Int(resultByte)] & MASK_LGT_AGT_EQ_OP
        if resultByte < x2 { setST(bits: BIT_C) }
        if (x1 & 0x80) == (x2 & 0x80) && (resultByte & 0x80) != (x2 & 0x80) { setST(bits: BIT_OV) }
    }

    func op_abs() {
        decodeFormatVI()
        fixS()
        let x1 = romword(S: S)

        if x1 & 0x8000 != 0 {
            let x2 = (~x1) &+ 1
            wrword(D: S, V: x2)
            addCycles(14)
        } else {
            addCycles(12)
        }

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ_OV
    }

    func op_ai() {
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        let imm = romword(S: PC)
        addPC(2)

        addCycles(14)
        let x1 = romword(S: D)
        let x3 = x1 &+ imm
        wrword(D: D, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 < x1 { setST(bits: BIT_C) }
        if (x1 & 0x8000) == (imm & 0x8000) && (x3 & 0x8000) != (imm & 0x8000) { setST(bits: BIT_OV) }
    }

    func op_dec() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = x1 &- 1
        wrword(D: S, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 != 0xFFFF { setST(bits: BIT_C) }
        if x3 == 0x7FFF { setST(bits: BIT_OV) }
    }

    func op_dect() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = x1 &- 2
        wrword(D: S, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 < 0xFFFE { setST(bits: BIT_C) }
        if x3 == 0x7FFF || x3 == 0x7FFE { setST(bits: BIT_OV) }
    }

    func op_div() {
        addCycles(16)
        decodeFormatIX()
        fixS()
        let x2 = romword(S: S)

        D = WP &+ (D << 1)
        let x3high = romword(S: D)

        if x2 > x3high {
            let x3 = (UInt32(x3high) << 16) | UInt32(romword(S: D &+ 2))
            var mask: UInt32 = 0xFFFF8000
            var divisor: UInt32 = UInt32(x2) << 15
            var cnt = 16
            var quotient: UInt16 = 0
            var remainder = x3

            while x2 <= UInt16(truncatingIfNeeded: remainder >> 16) || cnt > 0 {
                if UInt32(x2) <= UInt32(remainder >> 16) || cnt <= 0 { break }
                quotient <<= 1
                if (remainder & mask) >= divisor {
                    quotient |= 1
                    remainder -= divisor
                }
                mask >>= 1
                divisor >>= 1
                cnt -= 1
                addCycles(1)
            }
            // Use simpler division for correctness
            let q = UInt16(x3 / UInt32(x2))
            let r = UInt16(x3 % UInt32(x2))
            wrword(D: D, V: q)
            wrword(D: D &+ 2, V: r)
            resetST(BIT_OV)
            addCycles(92 - 16)
        } else {
            setST(bits: BIT_OV)
        }
    }

    func op_inc() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = x1 &+ 1
        wrword(D: S, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ_OV_C
    }

    func op_inct() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = x1 &+ 2
        wrword(D: S, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 < 2 { setST(bits: BIT_C) }
        if x3 == 0x8000 || x3 == 0x8001 { setST(bits: BIT_OV) }
    }

    func op_mpy() {
        addCycles(52)
        decodeFormatIX()
        fixS()
        let x1 = UInt32(romword(S: S))

        D = WP &+ (D << 1)
        let x3 = UInt32(romword(S: D)) * x1
        wrword(D: D, V: UInt16((x3 >> 16) & 0xFFFF))
        wrword(D: D &+ 2, V: UInt16(x3 & 0xFFFF))
    }

    func op_neg() {
        decodeFormatVI()
        fixS()
        addCycles(12)
        let x1 = romword(S: S)
        let x3 = (~x1) &+ 1
        wrword(D: S, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ_OV_C
    }

    func op_s() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x2 &- x1
        wrword(D: D, V: x3)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
        if x3 < x2 || x1 == 0 { setST(bits: BIT_C) }
        if (x1 & 0x8000) != (x2 & 0x8000) && (x3 & 0x8000) != (x2 & 0x8000) { setST(bits: BIT_OV) }
    }

    func op_sb() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let x2: UInt16
        let resultByte: UInt16
        let newXD: UInt16

        if D & 1 != 0 {
            x2 = xD & 0xFF
            resultByte = (x2 &- x1) & 0xFF
            newXD = (xD & 0xFF00) | resultByte
        } else {
            x2 = xD >> 8
            resultByte = (x2 &- x1) & 0xFF
            newXD = (xD & 0x00FF) | (resultByte << 8)
        }
        wrword(D: D, V: newXD)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV | BIT_OP)
        ST |= TMS9900.bStatusLookup[Int(resultByte)] & MASK_LGT_AGT_EQ_OP
        if resultByte < x2 || x1 == 0 { setST(bits: BIT_C) }
        if (x1 & 0x80) != (x2 & 0x80) && (resultByte & 0x80) != (x2 & 0x80) { setST(bits: BIT_OV) }
    }
}

// MARK: - Branch Operations
extension TMS9900 {

    func op_b() {
        addCycles(8)
        decodeFormatVI()
        fixS()
        _ = romword(S: S)
        setPC(S)
    }

    func op_bl() {
        addCycles(12)
        decodeFormatVI()
        fixS()
        _ = romword(S: S)
        if nReturnAddress == 0 { nReturnAddress = PC }
        wrword(D: WP &+ 22, V: PC)
        setPC(S)
    }

    func op_blwp() {
        addCycles(26)
        decodeFormatVI()
        fixS()
        let x1 = romword(S: S)  // new WP from vector address
        if nReturnAddress == 0 { nReturnAddress = PC }
        let x2 = WP
        setWP(x1)
        wrword(D: WP &+ 26, V: x2)
        wrword(D: WP &+ 28, V: PC)
        wrword(D: WP &+ 30, V: ST)
        setPC(romword(S: S &+ 2))
        skip_interrupt = 2
    }

    func op_rtwp() {
        addCycles(14)
        setST(romword(S: WP &+ 30))
        setPC(romword(S: WP &+ 28))
        setWP(romword(S: WP &+ 26))
        // Per TMS9900 spec the next instruction in the returned context runs
        // before another interrupt can be recognised. Without this, an ISR
        // that returns while its interrupt source is still asserted (e.g. VDP
        // INT held until the status register is read) is taken again
        // immediately, before the returned-to code can clear the source.
        skip_interrupt = 2
    }

    func op_x() {
        addCycles(4)  // 8 - 4 already counted
        decodeFormatVI()
        fixS()
        let x1 = romword(S: S)
        currentOp = x1

        X_flag = PC
        executeOpcode(currentOp)
        X_flag = 0
    }

    func op_xop() {
        addCycles(36)
        decodeFormatIX()
        fixS()
        D &= 0xF

        _ = romword(S: S)  // read source (unused)

        let x1 = WP
        setWP(romword(S: 0x0040 &+ (D << 2)))
        wrword(D: WP &+ 22, V: S)
        wrword(D: WP &+ 26, V: x1)
        wrword(D: WP &+ 28, V: PC)
        wrword(D: WP &+ 30, V: ST)
        setPC(romword(S: 0x0042 &+ (D << 2)))
        setST(bits: BIT_XOP)
        skip_interrupt = 2
    }
}

// MARK: - Jump Operations
extension TMS9900 {
    func op_jeq() { doJump(ST_EQ) }
    func op_jgt() { doJump(ST_AGT) }
    func op_jhe() { doJump(ST_LGT || ST_EQ) }
    func op_jh()  { doJump(ST_LGT && !ST_EQ) }
    func op_jl()  { doJump(!ST_LGT && !ST_EQ) }
    func op_jle() { doJump(!ST_LGT || ST_EQ) }
    func op_jlt() { doJump(!ST_AGT && !ST_EQ) }
    func op_jmp() { doJump(true) }
    func op_jnc() { doJump(!ST_C) }
    func op_jne() { doJump(!ST_EQ) }
    func op_jno() { doJump(!ST_OV) }
    func op_jop() { doJump(ST_OP) }
    func op_joc() { doJump(ST_C) }
}

// MARK: - Compare Operations
extension TMS9900 {

    func op_c() {
        addCycles(14)
        decodeFormatI()
        let savedTd = Td, savedTs = Ts, savedD = D, savedS = S
        fixS()
        let resolvedS = S
        let x1 = romword(S: S)
        fixD()
        let resolvedD = D
        let x2 = romword(S: D)

        // TEMP cassette debug: trace the cassette ISR's wait-loop compare
        // (`C *R14, @>13F0(R0)` at >1410).
        if currentOp == 0x881E && WP == 0x83C0 && TMS9900.cDebugLogCount < 5 {
            TMS9900.cDebugLogCount += 1
            print(String(format:
                "[op_c] op=%04X Td=%d D=%d Ts=%d S=%d resolvedS=%04X resolvedD=%04X x1=%04X x2=%04X eq=%@",
                currentOp, savedTd, savedD, savedTs, savedS,
                resolvedS, resolvedD, x1, x2, x1 == x2 ? "YES" : "no"))
        }

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        if x1 > x2 { setST(bits: BIT_LGT) }
        if x1 == x2 { setST(bits: BIT_EQ) }
        if (x1 & 0x8000) == (x2 & 0x8000) {
            if x1 > x2 { setST(bits: BIT_AGT) }
        } else {
            if x2 & 0x8000 != 0 { setST(bits: BIT_AGT) }
        }
    }

    func op_cb() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let x2: UInt16 = (D & 1 != 0) ? (xD & 0xFF) : (xD >> 8)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ | BIT_OP)
        if x1 > x2 { setST(bits: BIT_LGT) }
        if x1 == x2 { setST(bits: BIT_EQ) }
        if (x1 & 0x80) == (x2 & 0x80) {
            if x1 > x2 { setST(bits: BIT_AGT) }
        } else {
            if x2 & 0x80 != 0 { setST(bits: BIT_AGT) }
        }
        ST |= TMS9900.bStatusLookup[Int(x1)] & BIT_OP
    }

    func op_ci() {
        addCycles(14)
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        let imm = romword(S: PC)
        addPC(2)
        let x3 = romword(S: D)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        if x3 > imm { setST(bits: BIT_LGT) }
        if x3 == imm { setST(bits: BIT_EQ) }
        if (x3 & 0x8000) == (imm & 0x8000) {
            if x3 > imm { setST(bits: BIT_AGT) }
        } else {
            if imm & 0x8000 != 0 { setST(bits: BIT_AGT) }
        }
    }

    func op_coc() {
        Td = 0
        Ts = (currentOp & 0x0030) >> 4
        D  = (currentOp & 0x03C0) >> 6
        S  = currentOp & 0x000F
        B  = 0
        fixS()
        addCycles(14)
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x1 & x2

        if x3 == x1 { setST(bits: BIT_EQ) } else { resetST(BIT_EQ) }
    }

    func op_czc() {
        Td = 0
        Ts = (currentOp & 0x0030) >> 4
        D  = (currentOp & 0x03C0) >> 6
        S  = currentOp & 0x000F
        B  = 0
        fixS()
        addCycles(14)
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x1 & x2

        if x3 == 0 { setST(bits: BIT_EQ) } else { resetST(BIT_EQ) }
    }
}

// MARK: - CRU Operations
extension TMS9900 {

    func op_ldcr() {
        addCycles(20)
        D = (currentOp & 0x03C0) >> 6
        Ts = (currentOp & 0x0030) >> 4
        S = currentOp & 0x000F
        B = D < 9 ? 1 : 0
        fixS()

        if D == 0 { D = 16 }
        let x1: UInt16 = D < 9 ? UInt16(rcpubyte(S)) : romword(S: S)

        var x3: UInt16 = 1
        let cruBase = Int((romword(S: WP &+ 24) >> 1) & 0xFFF)
        for x2 in 0..<Int(D) {
            core.writeIOByte(address: cruBase + x2, cycles: &nCycleCount, accessType: .write,
                             data: (x1 & x3) != 0 ? 1 : 0)
            x3 <<= 1
        }

        addCycles(2 * Int(D))

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        if D < 9 {
            resetST(BIT_OP)
            ST |= TMS9900.bStatusLookup[Int(x1 & 0xFF)] & MASK_LGT_AGT_EQ_OP
        } else {
            ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        }
    }

    func op_sbo() {
        var add: UInt16
        D = currentOp & 0x00FF
        addCycles(12)
        add = romword(S: WP &+ 24) >> 1
        if D & 0x80 != 0 {
            add = add &- (128 &- (D & 0x7F))
        } else {
            add = add &+ D
        }
        core.writeIOByte(address: Int(add), cycles: &nCycleCount, accessType: .write, data: 1)
    }

    func op_sbz() {
        var add: UInt16
        D = currentOp & 0x00FF
        addCycles(12)
        add = romword(S: WP &+ 24) >> 1
        if D & 0x80 != 0 {
            add = add &- (128 &- (D & 0x7F))
        } else {
            add = add &+ D
        }
        core.writeIOByte(address: Int(add), cycles: &nCycleCount, accessType: .write, data: 0)
    }

    func op_stcr() {
        addCycles(42)
        D = (currentOp & 0x03C0) >> 6
        Ts = (currentOp & 0x0030) >> 4
        S = currentOp & 0x000F
        B = D < 9 ? 1 : 0
        fixS()

        if D == 0 { D = 16 }
        var x1: UInt16 = 0
        var x3: UInt16 = 1

        let cruBase = Int((romword(S: WP &+ 24) >> 1) & 0xFFF)
        for x2 in 0..<Int(D) {
            let x4 = core.readIOByte(address: cruBase + x2, cycles: &nCycleCount, accessType: .read)
            if x4 != 0 { x1 |= x3 }
            x3 <<= 1
        }

        if D < 9 {
            wcpubyte(S, UInt8(x1 & 0xFF))
        } else {
            _ = romword(S: S, rmw: .rmw)  // wasted read
            wrword(D: S, V: x1)
        }

        if D < 8 {
            // no extra cycles
        } else if D < 9 {
            addCycles(2)  // 44-42
        } else if D < 16 {
            addCycles(16)  // 58-42
        } else {
            addCycles(18)  // 60-42
        }

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        if D < 9 {
            resetST(BIT_OP)
            ST |= TMS9900.bStatusLookup[Int(x1 & 0xFF)] & MASK_LGT_AGT_EQ_OP
        } else {
            ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        }
    }

    func op_tb() {
        var add: UInt16
        D = currentOp & 0x00FF
        addCycles(12)
        add = romword(S: WP &+ 24) >> 1
        if D & 0x80 != 0 {
            add = add &- (128 &- (D & 0x7F))
        } else {
            add = add &+ D
        }
        let val = core.readIOByte(address: Int(add), cycles: &nCycleCount, accessType: .read)
        if val != 0 { setST(bits: BIT_EQ) } else { resetST(BIT_EQ) }
    }
}

// MARK: - Load/Store Operations
extension TMS9900 {

    func op_li() {
        addCycles(12)
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        let imm = romword(S: PC)
        addPC(2)
        wrword(D: D, V: imm)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(imm)] & MASK_LGT_AGT_EQ
    }

    func op_limi() {
        addCycles(16)
        let imm = romword(S: PC)
        addPC(2)
        setST((ST & 0xFFF0) | (imm & 0x0F))
    }

    func op_lwpi() {
        addCycles(10)
        let imm = romword(S: PC)
        addPC(2)
        setWP(imm)
    }

    func op_mov() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = romword(S: S)
        fixD()
        _ = romword(S: D)  // read dest (wasted)
        wrword(D: D, V: x1)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
    }

    func op_movb() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let newXD: UInt16
        if D & 1 != 0 {
            newXD = (xD & 0xFF00) | x1
        } else {
            newXD = (xD & 0x00FF) | (x1 << 8)
        }
        wrword(D: D, V: newXD)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ | BIT_OP)
        ST |= TMS9900.bStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ_OP
    }

    func op_stst() {
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        addCycles(8)
        wrword(D: D, V: ST)
    }

    func op_stwp() {
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        addCycles(8)
        wrword(D: D, V: WP)
    }

    func op_swpb() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = ((x1 & 0xFF) << 8) | (x1 >> 8)
        wrword(D: S, V: x3)
    }
}

// MARK: - Logic Operations
extension TMS9900 {

    func op_andi() {
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        let imm = romword(S: PC)
        addPC(2)
        addCycles(14)
        let x1 = romword(S: D)
        let x3 = x1 & imm
        wrword(D: D, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_ori() {
        D = currentOp & 0x000F
        D = WP &+ (D << 1)
        let imm = romword(S: PC)
        addPC(2)
        addCycles(14)
        let x1 = romword(S: D)
        let x3 = x1 | imm
        wrword(D: D, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_xor() {
        Td = 0
        Ts = (currentOp & 0x0030) >> 4
        D  = (currentOp & 0x03C0) >> 6
        S  = currentOp & 0x000F
        B  = 0
        fixS()
        addCycles(14)
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x1 ^ x2
        wrword(D: D, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_inv() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        let x1 = romword(S: S)
        let x3 = ~x1
        wrword(D: S, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_clr() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        _ = romword(S: S)
        wrword(D: S, V: 0)
    }

    func op_seto() {
        decodeFormatVI()
        fixS()
        addCycles(10)
        _ = romword(S: S)
        wrword(D: S, V: 0xFFFF)
    }

    func op_soc() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = x1 | x2
        wrword(D: D, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_socb() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let x2: UInt16
        let resultByte: UInt16
        let newXD: UInt16

        if D & 1 != 0 {
            x2 = xD & 0xFF
            resultByte = (x1 | x2) & 0xFF
            newXD = (xD & 0xFF00) | resultByte
        } else {
            x2 = xD >> 8
            resultByte = (x1 | x2) & 0xFF
            newXD = (xD & 0x00FF) | (resultByte << 8)
        }
        wrword(D: D, V: newXD)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ | BIT_OP)
        ST |= TMS9900.bStatusLookup[Int(resultByte)] & MASK_LGT_AGT_EQ_OP
    }

    func op_szc() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = romword(S: S)
        fixD()
        let x2 = romword(S: D)
        let x3 = (~x1) & x2
        wrword(D: D, V: x3)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ)
        ST |= TMS9900.wStatusLookup[Int(x3)] & MASK_LGT_AGT_EQ
    }

    func op_szcb() {
        addCycles(14)
        decodeFormatI()
        fixS()
        let x1 = UInt16(rcpubyte(S))
        fixD()
        let xD = romword(S: D)
        let x2: UInt16
        let resultByte: UInt16
        let newXD: UInt16

        if D & 1 != 0 {
            x2 = xD & 0xFF
            resultByte = (~x1 & x2) & 0xFF
            newXD = (xD & 0xFF00) | resultByte
        } else {
            x2 = xD >> 8
            resultByte = (~x1 & x2) & 0xFF
            newXD = (xD & 0x00FF) | (resultByte << 8)
        }
        wrword(D: D, V: newXD)

        resetST(BIT_LGT | BIT_AGT | BIT_EQ | BIT_OP)
        ST |= TMS9900.bStatusLookup[Int(resultByte)] & MASK_LGT_AGT_EQ_OP
    }
}

// MARK: - Shift Operations
extension TMS9900 {

    private func decodeShift() -> (x1: UInt16, count: UInt16) {
        var count = (currentOp & 0x00F0) >> 4
        S = currentOp & 0x000F
        S = WP &+ (S << 1)

        if count == 0 {
            count = romword(S: WP) & 0xF
            if count == 0 { count = 16 }
            addCycles(8)
        }
        addCycles(12 + 2 * Int(count))
        let x1 = romword(S: S)
        return (x1, count)
    }

    func op_sra() {
        var (x1, count) = decodeShift()
        let x4 = x1 & 0x8000
        var x3: UInt16 = 0

        for _ in 0..<count {
            x3 = x1 & 1
            x1 >>= 1
            x1 |= x4
        }
        wrword(D: S, V: x1)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C)
        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        if x3 != 0 { setST(bits: BIT_C) }
    }

    func op_srl() {
        var (x1, count) = decodeShift()
        var x3: UInt16 = 0

        for _ in 0..<count {
            x3 = x1 & 1
            x1 >>= 1
        }
        wrword(D: S, V: x1)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C)
        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        if x3 != 0 { setST(bits: BIT_C) }
    }

    func op_sla() {
        var (x1, count) = decodeShift()
        let x4 = x1 & 0x8000

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C | BIT_OV)
        var x3: UInt16 = 0

        for _ in 0..<count {
            x3 = x1 & 0x8000
            x1 <<= 1
            if (x1 & 0x8000) != x4 { setST(bits: BIT_OV) }
        }
        wrword(D: S, V: x1)

        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        if x3 != 0 { setST(bits: BIT_C) }
    }

    func op_src() {
        var count = (currentOp & 0x00F0) >> 4
        S = currentOp & 0x000F
        S = WP &+ (S << 1)

        if count == 0 {
            count = romword(S: WP) & 0xF
            if count == 0 { count = 16 }
            addCycles(8)
        }
        addCycles(12)
        var x1 = romword(S: S)
        var x4: UInt16 = 0

        for _ in 0..<count {
            x4 = x1 & 0x1
            x1 >>= 1
            if x4 != 0 { x1 |= 0x8000 }
        }
        wrword(D: S, V: x1)

        resetST(BIT_EQ | BIT_LGT | BIT_AGT | BIT_C)
        ST |= TMS9900.wStatusLookup[Int(x1)] & MASK_LGT_AGT_EQ
        if x4 != 0 { setST(bits: BIT_C) }

        addCycles(2 * Int(count))
    }
}

// MARK: - Special/Invalid Operations
extension TMS9900 {

    func op_ckof() {
        addCycles(12)
        // not supported on 99/4A
    }

    func op_ckon() {
        addCycles(12)
        // not supported on 99/4A
    }

    func op_idle() {
        addCycles(12)
        idling = true
    }

    func op_rset() {
        addCycles(12)
        ST &= 0xFFF0
    }

    func op_lrex() {
        addCycles(12)
        // not supported on 99/4A
    }

    func op_bad() {
        addCycles(6)
        // illegal opcode - do nothing
    }
}
