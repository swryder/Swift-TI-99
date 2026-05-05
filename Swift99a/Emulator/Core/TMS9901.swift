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
// Cassette I/O lives on this chip (Nouspikel): bit 22 = Motor #1 (CS1),
// bit 23 = Motor #2 (CS2), bit 24 = Audio gate (1 silences tape audio),
// bit 25 = Data output to tape (CDOC), bit 27 = Data input from CS1 (CDIN).
// Console ROM accesses these with R12=>0024, e.g. SBO 4 = bit 22.
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

    /// Cassette device that drives CDIN (bit 27). When nil, CDIN reads as 0.
    weak var cassette: Cassette?

    /// CPU reference. Used to compute current emulator µs from
    /// `totalCycleCount` so the timer can fire at proper rate even when
    /// the emulator is running in coarse slices.
    weak var cpu: TMS9900?

    // Clock/timer mode flag (bit 0 write)
    private var clockMode: Bool = false

    // TMS9901 interrupt enable mask. Per datasheet, all mask bits (M2-M16,
    // i.e. bits 1-15 in our addressing) are SET to logic 1 at chip reset —
    // so every interrupt input is enabled by default and the ROM masks
    // specific ones with SBZ as needed. Bit N = 1 means level N is allowed
    // to propagate to the CPU. Bit 0 is the clock-mode flag and is unused
    // here.
    private var intMask: UInt16 = 0xFFFE

    // Cassette interface state (TMS9901 CRU bits 22, 23, 24, 25, 27).
    // The Cassette device reads these flags to decide whether to advance the
    // tape and feed audio through the speaker.
    private(set) var cs1MotorOn: Bool = false
    private(set) var cs2MotorOn: Bool = false
    private(set) var cassetteAudioGateClosed: Bool = false
    private(set) var cassetteDataOut: Bool = false

    // MARK: - Internal timer
    //
    // The 9901 has a 14-bit decrement-on-clock timer. CPU writes the load
    // value via CRU bits 1–14 while clock-mode (bit 0 = 1) is asserted, then
    // SBZ 0 exits clock mode and the timer starts counting toward zero. At
    // zero it fires a level-3 interrupt and reloads from the saved value.
    // The cassette read routine in the console ROM is built around this
    // interrupt — without it, the routine never recovers timing for the
    // FSK signal and trap-loops at >1574.
    //
    // Counting rate is φ/64. On a 3MHz TMS9900 each timer tick is 64 CPU
    // cycles. We measure elapsed time directly in CPU cycles (read from
    // `cpu.totalCycleCount`) so there's no drift between the timer's
    // reference point and the CPU's "now" — that drift was producing
    // bimodal fire periods (1344 cyc / 6000 cyc) instead of the steady
    // ~2170 cyc Classic99 produces under the same conditions.
    private static let cyclesPerTick: Int = 64

    /// 14-bit value loaded by the CPU. Zero disables the timer.
    private var timerInitial: UInt16 = 0

    /// CPU cycle count at which the timer last started or reloaded.
    /// Set when SBZ 0 exits clock mode; advanced by `cellCycles` per fire.
    private var timerStartCycle: Int = 0

    /// Number of expiries that have already triggered an interrupt request.
    /// Cleared whenever the timer is (re)started so a freshly-loaded timer
    /// fires from zero.
    private var timerFiresDelivered: Int = 0

    /// Latched timer-interrupt-pending flag. The TMS9901 sets this when the
    /// timer expires; it stays set until the CPU acknowledges by writing to
    /// CRU bit 3 (in I/O mode), which both enables the mask and clears the
    /// latch. The TI-99/4A wires this onto CPU INT2 (level 1) — the same
    /// vector as VDP — so the cassette ROM's level-1 ISR sees timer ticks
    /// at the bit-cell rate (~363 µs) for FSK decoding.
    private var timerIntReq: Bool = false

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TMS9901", index: index)
        return true
    }

    private var debugTimerFireCount: Int = 0
    private var debugTimerAckCount: Int = 0

    override func operate(timestamp: Double) -> Bool {
        // The actual fire logic (with trace logging) lives in
        // `updateLevel1Request()` so we don't have two slightly-different
        // copies of it. This used to mirror that function's logic but
        // without the trace hook, which silently dropped every fire from
        // the trace.
        updateLevel1Request()
        return true
    }

    /// TEMP debug counter for level-1 transitions.
    private var debugLastLevel1Asserted: Bool? = nil
    private var debugLevel1TransitionCount: Int = 0

    /// TEMP: enable to log *every* level-1 update call (not just transitions),
    /// limited to a window after motor-on so we don't flood the boot log.
    private var debugVerboseLevelLog: Bool = false

    /// Recompute whether level-1 should be asserted to the CPU and push the
    /// result through `requestInt`/`clearInt`. Called from `operate()` once
    /// per emulator slice, *and* immediately after any CRU write that could
    /// change the answer (mask bits 1-3, timer ack on bit 3). The
    /// instruction-boundary call is essential: without it, an interrupt
    /// request that was just ack'd inside an ISR doesn't actually drop until
    /// the next slice, so the CPU's next int-pending check re-takes the
    /// interrupt before the returned-to code can run.
    /// Public entry point for the CPU's per-instruction interrupt check.
    /// Calls into `updateLevel1Request` so the timer can be re-evaluated at
    /// instruction granularity rather than only at slice boundaries.
    func refreshInterruptRequest() {
        updateLevel1Request()
    }

    private func updateLevel1Request() {
        // Re-evaluate the timer using the CPU's current cycle count so a
        // small `timerInitial` value can produce many fires within one
        // emulator slice. Cycle-based math (vs the µs-via-currentTimestamp
        // approach this used to use) keeps the timer reference point in
        // lockstep with `cpu.totalCycleCount`, which is what every fire
        // check reads — no drift between "when SBZ 0 was processed" and
        // "what time the CPU thinks it is now."
        if !clockMode, timerInitial > 0, !timerIntReq, let cpu = cpu {
            let cellCycles = Int(timerInitial) * Self.cyclesPerTick
            let elapsed = cpu.totalCycleCount - timerStartCycle
            if elapsed >= cellCycles {
                timerIntReq = true
                timerStartCycle += cellCycles * (elapsed / cellCycles)
                debugTimerFireCount += 1
                // [trace] mirror Classic99 TIMERFIRE start=N
                CassetteTrace.log(currentCycle: cpu.totalCycleCount,
                                  event: "TIMERFIRE",
                                  details: "start=\(timerInitial)")
                if debugTimerFireCount <= 5 || debugTimerFireCount % 100_000 == 0 {
                    print("[TMS9901] timer FIRE #\(debugTimerFireCount) " +
                          "(timerInitial=\(timerInitial))")
                }
            }
        }

        let vdpEnabled    = (intMask & (1 << 2)) != 0
        let timerEnabled  = (intMask & (1 << 3)) != 0
        let vdpAsserted   = vdpEnabled    && (vdp?.isIntActive() ?? false)
        let timerAssertedAndEnabled = timerEnabled && timerIntReq
        let shouldAssert = vdpAsserted || timerAssertedAndEnabled

        // TEMP: log every transition with the source (VDP / timer / both)
        // so we can see whether the level-1 line is dropping when ack'd and
        // who's pulling it back up.
        if debugLastLevel1Asserted != shouldAssert {
            debugLevel1TransitionCount += 1
            if debugLevel1TransitionCount <= 5 || debugLevel1TransitionCount % 100_000 == 0 {
                let src = vdpAsserted && timerAssertedAndEnabled ? "VDP+timer"
                        : vdpAsserted ? "VDP"
                        : timerAssertedAndEnabled ? "timer"
                        : "none"
                print("[TMS9901] level-1 \(shouldAssert ? "ASSERT" : "drop  ")" +
                      " #\(debugLevel1TransitionCount) src=\(src) " +
                      "intMask=\(String(format:"%04X", intMask)) timerIntReq=\(timerIntReq)")
            }
            debugLastLevel1Asserted = shouldAssert
        }

        if shouldAssert {
            theCore?.requestInt(level: 1)
        } else {
            theCore?.clearInt(level: 1)
        }
    }

    /// Reads the current 14-bit timer value, used by clock-mode CRU reads
    /// of bits 1–14. While the timer is running this ramps from `timerInitial`
    /// down to zero and reloads. Cycle-based to stay in sync with the
    /// fire-detection logic above.
    private func currentTimerValue() -> UInt16 {
        guard timerInitial > 0 else { return 0 }
        if clockMode { return timerInitial }
        let nowCycles = cpu?.totalCycleCount ?? timerStartCycle
        let cellCycles = Int(timerInitial) * Self.cyclesPerTick
        let elapsed = nowCycles - timerStartCycle
        let withinCell = elapsed % cellCycles
        let ticksInto = withinCell / Self.cyclesPerTick
        let remaining = Int(timerInitial) - ticksInto
        return UInt16(max(0, min(0x3FFF, remaining)))
    }

    /// TEMP: counter for any read at bit 16+ — used to confirm whether the
    /// cassette read routine is actually polling the cassette/keyboard CRU
    /// range. Remove with the rest of the cassette debug logging.
    private var debugHighBitReadCount: Int = 0

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        // addr is the CRU bit number (0-31)
        if addr >= 16 {
            debugHighBitReadCount += 1
            if debugHighBitReadCount <= 3 || debugHighBitReadCount % 500_000 == 0 {
                print("[TMS9901] read bit \(addr) (#\(debugHighBitReadCount))")
            }
        }
        // In clock mode, bits 1–14 expose the timer's current count.
        if clockMode, addr >= 1, addr <= 14 {
            let bit = UInt16(addr - 1)
            return UInt8((currentTimerValue() >> bit) & 1)
        }

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

        case 27:
            // Bit 27: cassette data input from CS1 (CDIN).
            // Driven by the Cassette device's FSK signal when a tape is loaded;
            // reads as 0 otherwise.
            return cassette?.readDataIn() ?? 0

        default:
            // Bits 3+: keyboard and other I/O — handled by keyboard peripheral
            return 0
        }
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        switch addr {
        case 0:
            // Bit 0: enter/exit clock mode.
            let entering = (data != 0)
            if entering != clockMode {
                if !entering {
                    // I/O mode: (re)start the timer from `timerInitial`,
                    // anchored to the current CPU cycle (NOT the slice
                    // boundary's `currentTimestamp`, which can be ~1 ms
                    // ahead of the CPU at this instant and produced bimodal
                    // fire periods).
                    timerStartCycle = cpu?.totalCycleCount ?? 0
                    timerFiresDelivered = 0
                }
                clockMode = entering
            }

        case 1...14:
            if clockMode {
                // Clock mode: writing bit N (1..14) sets bit (N-1) of the
                // timer load value.
                let mask: UInt16 = 1 << UInt16(addr - 1)
                if data != 0 {
                    timerInitial |= mask
                } else {
                    timerInitial &= ~mask
                }
                timerInitial &= 0x3FFF
                // [trace] CRUWRITE matching Classic99 — log every set-bit
                // during the timer LDCR so we can see what start value
                // each emulator computes from the same ROM writes.
                if data != 0 {
                    CassetteTrace.log(currentCycle: cpu?.totalCycleCount ?? 0,
                                      event: "CRUWRITE",
                                      details: "op=SBO bit=\(addr) clockmode=1 starttimer=\(timerInitial)")
                }
            } else {
                // I/O mode: set/clear interrupt mask bit.
                let prev = intMask
                if data != 0 {
                    intMask |= (1 << UInt16(addr))
                } else {
                    intMask &= ~(1 << UInt16(addr))
                }
                // TEMP: log changes to mask bits 1-3 (peripheral, VDP,
                // timer) — these are the ones cassette manipulates.
                if addr >= 1 && addr <= 3 && prev != intMask {
                    let mn = data != 0 ? "SBO" : "SBZ"
                    print("[TMS9901] \(mn) \(addr) → intMask=" +
                          String(format: "%04X", intMask))
                }
                // CRU bit 3 has a special side effect on the TMS9901:
                // *any* write (SBO 3 *or* SBZ 3) clears a latched timer
                // interrupt request. This is how the cassette ISR ack's
                // each timer tick before the next one can fire — without
                // it the latch stays set and the interrupt loops forever.
                if addr == 3 {
                    let wasReq = timerIntReq
                    timerIntReq = false
                    // [trace] TIMERACK — matches Classic99 op=SBO/SBZ had=N
                    let op = data != 0 ? "SBO" : "SBZ"
                    CassetteTrace.log(currentCycle: cpu?.totalCycleCount ?? 0,
                                      event: "TIMERACK",
                                      details: "op=\(op) had=\(wasReq ? 1 : 0)")
                    if wasReq {
                        debugTimerAckCount += 1
                        if debugTimerAckCount <= 5 || debugTimerAckCount % 100_000 == 0 {
                            print("[TMS9901] timer ACK #\(debugTimerAckCount)")
                        }
                    }
                }
                // Mask changes (bits 1-3) and timer ack (bit 3) can change
                // whether level-1 should be asserted to the CPU. The CPU
                // checks `intReqLevel` at every instruction boundary, so we
                // need to update the request line *now*, not at the next
                // emulator-slice operate() — otherwise the bit decoder gets
                // re-preempted right after its first read.
                if addr >= 1 && addr <= 3 {
                    updateLevel1Request()
                }
            }

        case 15:
            // Bit 15 in clock mode latches the new timer value into the
            // running counter; in I/O mode it's the interrupt mask for
            // level 15. We treat the I/O-mode path as a normal mask write.
            if !clockMode {
                if data != 0 {
                    intMask |= (1 << UInt16(addr))
                } else {
                    intMask &= ~(1 << UInt16(addr))
                }
            }

        case 22:
            let new = (data != 0)
            if new != cs1MotorOn {
                print("[TMS9901] cs1MotorOn := \(new)")
            }
            cs1MotorOn = new

        case 23:
            let new = (data != 0)
            if new != cs2MotorOn {
                print("[TMS9901] cs2MotorOn := \(new)")
            }
            cs2MotorOn = new

        case 24:
            let new = (data != 0)
            if new != cassetteAudioGateClosed {
                print("[TMS9901] audioGateClosed := \(new)")
            }
            cassetteAudioGateClosed = new

        case 25:
            cassetteDataOut = (data != 0)

        default:
            // Bits 16+: I/O pins handled by keyboard peripheral
            break
        }
    }
}
