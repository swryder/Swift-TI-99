// Swift 99/a
//
// TMS5220.swift
// Emulation of the TMS5200/CD2501E Speech Synthesizer.
// Ported from MAME tms5220.cpp (BSD-3-Clause)
// copyright-holders: Frank Palazzolo, Aaron Giles, Jonathan Gevaryahu,
//                    Raphael Nabet, Couriersud, Michael Zapf
//
// The TMS5220 performs Linear Predictive Coding (LPC) speech synthesis:
//   - 10th-order lattice filter driven by pitch and energy parameters
//   - Native sample rate: 8 kHz (resampled to 44.1 kHz for audio output)
//   - Speech data can come from an external ROM (Speak command) or the
//     CPU via a 16-byte FIFO (Speak External command)
//   - Commands: Speak (0x50), Speak External (0x60), Reset (0x70),
//     Read Byte (0x10), Load Address (0x40), Read and Branch (0x30)
//
// Mapped at CPU address >9000 (read status) and >9400 (write command/data).
//
// How Extended Basic CALL SAY uses this chip:
//   1. Issues Load Address commands (5 nibbles) to point the speech ROM
//      at the vocabulary BST entry point.
//   2. Issues Read Byte commands to navigate the BST, comparing characters
//      to find the spoken word in the vocabulary.
//   3. Once found, issues another Load Address sequence to set the ROM
//      pointer to the LPC speech data for that word.
//   4. Issues a Speak command to begin playback from the ROM address.
//   The TMS5220 then reads LPC frames from the speech ROM autonomously
//   until it encounters a STOP frame (energy index 0xF).
//
// Architecture notes:
//   - operate() runs on the emulator thread and generates 8kHz samples into
//     a ring buffer, synchronized with the emulated CPU clock. This ensures
//     FIFO reads happen in lockstep with CPU writes.
//   - fillAudioBuffer() runs on the audio thread and resamples from the
//     ring buffer to 44.1kHz for output.
//   - Commands that require talkStatus==false (Load Address, Read Byte,
//     Read and Branch) are buffered and retried each sample via tryCommand().
//   - scheduleDummyRead: after Load Address, the first subsequent Read Byte
//     or Speak command performs a dummy speechROM.read(1) before the actual
//     operation (important for correct ROM pointer alignment in some
//     vocabulary BST traversals).

import Foundation

final class TMS5220: Peripheral, AudioSource {

    /// Speech synthesizer reads return live LPC status / FIFO state with
    /// side effects (status latch clear), so reads must go through `read()`.
    override var readsHaveSideEffects: Bool { true }

    private let speechLock = NSRecursiveLock()

    // Coefficient tables
    private let coeff = tms5200Coeff

    // Speech ROM
    let speechROM = SpeechROM()

    // Output sample rate
    private let outputSampleRate: Double = 44100
    private let speechSampleRate: Double = 8000

    // FIFO (16 bytes for Speak External)
    private static let fifoSize = 16
    private var fifo = [UInt8](repeating: 0, count: fifoSize)
    private var fifoHead: Int = 0
    private var fifoTail: Int = 0
    private var fifoCount: Int = 0
    private var fifoBitsTaken: Int = 0

    // Status flags matching MAME state
    private var SPEN: Bool = false          // Speak enable
    private var DDIS: Bool = false          // Speak external mode (data goes to FIFO)
    private var TALK: Bool = false          // Talk active
    private var TALKD: Bool = false         // Talk delayed (latched from TALK)
    private var previousTalkStatus: Bool = false
    private var bufferLow: Bool = true      // BL - FIFO <= 8 bytes
    private var bufferEmpty: Bool = true    // BE - FIFO empty

    // Command buffer (Tursi addition from legacy)
    private var hasCommand: Bool = false
    private var commandBuffer: UInt8 = 0

    // Read byte register
    private var readByteRegister: UInt8 = 0
    private var RDB_flag: Bool = false
    private var scheduleDummyRead: Bool = false

    // Frame index state (raw indices before table lookup)
    private var newFrameEnergyIdx: Int = 0
    private var newFramePitchIdx: Int = 0
    private var newFrameKIdx = [Int](repeating: 0, count: 10)

    // Current interpolated parameters
    private var currentEnergy: Int16 = 0
    private var currentPitch: Int16 = 0
    private var currentK = [Int16](repeating: 0, count: 10)

    // Previous energy (for lattice filter — latched each sample)
    private var previousEnergy: Int16 = 0

    // Old frame flags
    private var OLDE: Bool = true           // Old frame was silence (E=0)
    private var OLDP: Bool = true           // Old frame was unvoiced (P=0)

    // Zero-parameter flags
    private var zpar: Bool = false          // Zero ALL parameters
    private var uvZpar: Bool = false        // Zero k5-k10 (unvoiced)

    // Interpolation state machine
    private var subcycle: Int = 0           // 0-2 (A', A, B cycles)
    private var subcReload: Int = 1         // 1 for normal speech (FORCE_SUBC_RELOAD)
    private var PC: Int = 0                 // 0-12 (parameter counter)
    private var IP: Int = 0                 // 0-7 (interpolation period)
    private var inhibit: Bool = true        // Interpolation inhibit flag
    private var pitchZero: Bool = false     // Force pitch counter to zero

    // Synthesis filter state
    private var u = [Int32](repeating: 0, count: 11)  // Forward path
    private var x = [Int32](repeating: 0, count: 10)  // Delay line

    // LFSR for unvoiced excitation
    private var RNG: UInt16 = 0x1FFF

    // Excitation
    private var excitationData: Int16 = 0

    // Pitch counter
    private var pitchCount: Int = 0

    // Pre-generated sample ring buffer: operate() produces 8kHz samples
    // in sync with the emulator clock; fillAudioBuffer() consumes them
    // at 44.1kHz with nearest-neighbor resampling.  This prevents the
    // audio thread from running the synthesis ahead of the CPU, which
    // would drain the FIFO before the CPU ISR can refill it.
    private static let sampleRingSize = 4096           // ~0.5s at 8kHz
    private var sampleRing = [Int16](repeating: 0, count: sampleRingSize)
    private var sampleRingHead: Int = 0                // next write position (emulator thread)
    private var sampleRingTail: Int = 0                // next read position (audio thread)
    private var sampleRingCount: Int = 0               // samples available
    private var audioResampleAccum: Double = 0         // resampler state for audio callback

    // MARK: - Helper properties

    private var talkStatus: Bool { SPEN || TALKD }

    private var newFrameStopFlag: Bool { newFrameEnergyIdx == 0x0F }
    private var newFrameSilenceFlag: Bool { newFrameEnergyIdx == 0 }
    private var newFrameUnvoicedFlag: Bool { newFramePitchIdx == 0 }
    private var oldFrameSilenceFlag: Bool { OLDE }
    private var oldFrameUnvoicedFlag: Bool { OLDP }

    // MARK: - Init

    init(core: EmulatorSystem) {
        super.init(core: core)
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "TMS5220", index: index)
        deviceReset()
        return true
    }

    /// Generate speech samples at 8kHz in sync with the emulated CPU clock.
    /// Called from the emulator thread (runSystem) so FIFO access is
    /// synchronized with CPU writes — no race with the audio callback.
    override func operate(timestamp: Double) -> Bool {
        if lastTimestamp == 0 || timestamp < lastTimestamp {
            lastTimestamp = timestamp
            return true
        }

        let timePerSample = 1_000_000.0 / speechSampleRate  // 125 µs per sample

        speechLock.lock()
        defer { speechLock.unlock() }

        while lastTimestamp + timePerSample <= timestamp {
            let sample = generateSample()

            // Write to ring buffer (drop if full — shouldn't happen in practice)
            if sampleRingCount < Self.sampleRingSize {
                sampleRing[sampleRingHead] = sample
                sampleRingHead = (sampleRingHead + 1) % Self.sampleRingSize
                sampleRingCount += 1
            }

            lastTimestamp += timePerSample
        }

        return true
    }

    // MARK: - Peripheral Read/Write

    override func read(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess) -> UInt8 {
        cycles += 4  // Speech access adds wait states

        speechLock.lock()
        defer { speechLock.unlock() }

        // Try to flush pending command
        tryCommand()

        if RDB_flag {
            // Last command was Read Byte — return data register
            RDB_flag = false
            return readByteRegister
        } else {
            // Return status register
            let status = (talkStatus ? 0x80 : 0) | (bufferLow ? 0x40 : 0) | (bufferEmpty ? 0x20 : 0)
            return UInt8(status)
        }
    }

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        cycles += 4

        speechLock.lock()
        defer { speechLock.unlock() }

        // Try to flush pending command first
        tryCommand()

        if DDIS {
            // In Speak External mode: data goes to FIFO
            let oldBufferLow = bufferLow

            if fifoCount < Self.fifoSize {
                fifo[fifoTail] = data
                fifoTail = (fifoTail + 1) % Self.fifoSize
                fifoCount += 1
                updateFifoStatusAndInts()

                // SPEN activation on BL falling edge (FIFO passes half-full)
                if !SPEN && oldBufferLow && !bufferLow {
                    zpar = true
                    uvZpar = true
                    OLDE = true
                    OLDP = true
                    SPEN = true
                    TALK = true  // FAST_START_HACK
                    newFrameEnergyIdx = 0
                    newFramePitchIdx = 0
                    for i in 0..<4 { newFrameKIdx[i] = 0 }
                    for i in 4..<7 { newFrameKIdx[i] = 0xF }
                    for i in 7..<coeff.numK { newFrameKIdx[i] = 0x7 }
                }
            }
            // If FIFO full, data is dropped (caller should check ready)
        } else {
            // Command mode — load command buffer
            if hasCommand {
                return  // Buffer full, drop (caller should check ready)
            }
            hasCommand = true
            commandBuffer = data
        }
    }

    // MARK: - Command Processing
    private func tryCommand() {
        guard hasCommand else { return }

        switch commandBuffer & 0x70 {
        case 0x00, 0x20:
            // NOP (or rate control on 5220C, which we don't emulate)
            hasCommand = false

        case 0x10, 0x30, 0x40:
            // Read Byte, Read and Branch, Load Address — need TALK STATUS clear
            if !talkStatus {
                processCommand(commandBuffer)
                hasCommand = false
            }

        case 0x50:
            // Speak — NOP if already speaking
            if !talkStatus {
                processCommand(commandBuffer)
            }
            hasCommand = false

        case 0x60, 0x70:
            // Speak External, Reset — immediate
            processCommand(commandBuffer)
            hasCommand = false

        default:
            hasCommand = false
        }
    }

    private func processCommand(_ cmd: UInt8) {
        switch cmd & 0x70 {
        case 0x10:  // READ BYTE
            if scheduleDummyRead {
                scheduleDummyRead = false
                if speechROM.isLoaded {
                    _ = speechROM.read(1)
                }
            }
            if speechROM.isLoaded {
                readByteRegister = UInt8(speechROM.read(8) & 0xFF)
            }
            RDB_flag = true

        case 0x30:  // READ AND BRANCH
            RDB_flag = false
            if speechROM.isLoaded {
                speechROM.readAndBranch()
            }

        case 0x40:  // LOAD ADDRESS
            if speechROM.isLoaded {
                speechROM.loadAddress(cmd & 0x0F)
            }
            scheduleDummyRead = true

        case 0x50:  // SPEAK (from ROM)
            if scheduleDummyRead {
                scheduleDummyRead = false
                if speechROM.isLoaded {
                    _ = speechROM.read(1)
                }
            }
            SPEN = true
            TALK = true  // FAST_START_HACK
            DDIS = false
            zpar = true
            uvZpar = true
            OLDE = true
            OLDP = true
            newFrameEnergyIdx = 0
            newFramePitchIdx = 0
            for i in 0..<4 { newFrameKIdx[i] = 0 }
            for i in 4..<7 { newFrameKIdx[i] = 0xF }
            for i in 7..<coeff.numK { newFrameKIdx[i] = 0x7 }

        case 0x60:  // SPEAK EXTERNAL
            fifo = [UInt8](repeating: 0, count: Self.fifoSize)
            fifoHead = 0
            fifoTail = 0
            fifoCount = 0
            fifoBitsTaken = 0
            DDIS = true
            zpar = true
            uvZpar = true
            OLDE = true
            OLDP = true
            newFrameEnergyIdx = 0
            newFramePitchIdx = 0
            for i in 0..<4 { newFrameKIdx[i] = 0 }
            for i in 4..<7 { newFrameKIdx[i] = 0xF }
            for i in 7..<coeff.numK { newFrameKIdx[i] = 0x7 }
            RDB_flag = false

        case 0x70:  // RESET
            if scheduleDummyRead {
                scheduleDummyRead = false
                if speechROM.isLoaded {
                    _ = speechROM.read(1)
                }
            }
            deviceReset()

        default:
            break
        }

        updateFifoStatusAndInts()
    }

    // MARK: - FIFO Status

    private func updateFifoStatusAndInts() {
        // BL: set if FIFO count <= 8
        bufferLow = fifoCount <= 8

        // BE: set if FIFO empty
        if fifoCount == 0 {
            bufferEmpty = true
            if DDIS {
                TALK = false
                SPEN = false
            }
        } else {
            bufferEmpty = false
        }

        // Talk status transition detection
        let ts = talkStatus
        if previousTalkStatus && !ts {
            DDIS = false
        }
        previousTalkStatus = ts
    }

    // MARK: - Bit Extraction

    /// Extract bits from FIFO or ROM.
    /// Ported from tms5220_device::extract_bits()
    private func extractBits(_ count: Int) -> Int {
        var val = 0

        if DDIS {
            // Extract from FIFO, one bit at a time
            for _ in 0..<count {
                val = (val << 1) | ((Int(fifo[fifoHead]) >> fifoBitsTaken) & 1)
                fifoBitsTaken += 1
                if fifoBitsTaken >= 8 {
                    fifoCount -= 1
                    fifo[fifoHead] = 0
                    fifoHead = (fifoHead + 1) % Self.fifoSize
                    fifoBitsTaken = 0
                    updateFifoStatusAndInts()
                }
            }
        } else {
            // Extract from speech ROM
            if speechROM.isLoaded {
                val = speechROM.read(count)
            } else {
                // If nothing connected, return all 1s (will eventually produce a STOP frame)
                val = (1 << count) - 1
            }
        }

        return val
    }

    // MARK: - Frame Parsing

    /// Parse a new LPC frame from the data stream.
    /// Ported from tms5220_device::parse_frame()
    private func parseFrame() {
        // Clear zero-parameter flags at frame start
        uvZpar = false
        zpar = false

        // Check buffer status for speak external
        updateFifoStatusAndInts()
        if DDIS && bufferEmpty { return }

        // Extract energy index
        newFrameEnergyIdx = extractBits(coeff.energyBits)
        updateFifoStatusAndInts()
        if DDIS && bufferEmpty { return }

        // Silent frame (energy = 0) or stop frame (energy = 15)
        if newFrameEnergyIdx == 0 || newFrameEnergyIdx == 15 {
            if newFrameStopFlag {
                TALK = false
                SPEN = false
                updateFifoStatusAndInts()
            }
            return
        }

        // Extract repeat flag
        let repFlag = extractBits(1)

        // Extract pitch index
        newFramePitchIdx = extractBits(coeff.pitchBits)
        // If unvoiced, zero k5-k10
        uvZpar = newFrameUnvoicedFlag
        updateFifoStatusAndInts()
        if DDIS && bufferEmpty { return }

        // If repeat frame, reuse old K coefficients
        if repFlag != 0 { return }

        // Extract first 4 K coefficients
        for i in 0..<4 {
            newFrameKIdx[i] = extractBits(coeff.kBits[i])
            updateFifoStatusAndInts()
            if DDIS && bufferEmpty { return }
        }

        // If unvoiced, only need K1-K4
        if newFramePitchIdx == 0 { return }

        // Extract remaining K5-K10
        for i in 4..<coeff.numK {
            newFrameKIdx[i] = extractBits(coeff.kBits[i])
            updateFifoStatusAndInts()
            if DDIS && bufferEmpty { return }
        }
    }

    // MARK: - Synthesis

    private func deviceReset() {
        hasCommand = false

        // FIFO
        fifo = [UInt8](repeating: 0, count: Self.fifoSize)
        fifoHead = 0
        fifoTail = 0
        fifoCount = 0
        fifoBitsTaken = 0

        // Status
        SPEN = false
        DDIS = false
        TALK = false
        TALKD = false
        previousTalkStatus = false
        bufferEmpty = true
        bufferLow = true

        RDB_flag = false
        scheduleDummyRead = false

        // Frame state
        newFrameEnergyIdx = 0
        newFramePitchIdx = 0
        newFrameKIdx = [Int](repeating: 0, count: 10)
        currentEnergy = 0
        currentPitch = 0
        currentK = [Int16](repeating: 0, count: 10)
        previousEnergy = 0

        OLDE = true
        OLDP = true
        zpar = false
        uvZpar = false

        // Interpolation
        inhibit = true
        subcycle = 0
        subcReload = 1  // FORCE_SUBC_RELOAD
        PC = 0
        IP = 0
        pitchZero = false
        pitchCount = 0

        // Filter
        u = [Int32](repeating: 0, count: 11)
        x = [Int32](repeating: 0, count: 10)
        RNG = 0x1FFF
        excitationData = 0

        // Reset speech ROM — calls load_address(0) then read(1) to put the
        // ROM pointer in a clean state, matching the documented hardware
        // device_reset behavior.
        speechROM.deviceReset()

        // Clear sample ring buffer
        sampleRingHead = 0
        sampleRingTail = 0
        sampleRingCount = 0
        audioResampleAccum = 0
    }

    /// Matrix multiply for lattice filter.
    /// a is the K coefficient (clamped to 10-bit signed: -512..511)
    /// b is the running result (clamped to 14-bit signed: -16384..16383)
    /// Returns (a * b) >> 9
    /// Ported from tms5220_device::matrix_multiply()
    @inline(__always)
    private func matrixMultiply(_ a: Int32, _ b: Int32) -> Int32 {
        var sa = a
        var sb = b
        // Wrap to 10-bit signed
        while sa > 511 { sa -= 1024 }
        while sa < -512 { sa += 1024 }
        // Wrap to 14-bit signed
        while sb > 16383 { sb -= 32768 }
        while sb < -16384 { sb += 32768 }
        return (sa * sb) >> 9
    }

    /// Lattice filter — execute one full run.
    /// Ported from tms5220_device::lattice_filter()
    @inline(__always)
    private func latticeFilter() -> Int32 {
        u[10] = matrixMultiply(Int32(previousEnergy), Int32(excitationData) << 6)
        u[9] = u[10] - matrixMultiply(Int32(currentK[9]), x[9])
        u[8] = u[9]  - matrixMultiply(Int32(currentK[8]), x[8])
        u[7] = u[8]  - matrixMultiply(Int32(currentK[7]), x[7])
        u[6] = u[7]  - matrixMultiply(Int32(currentK[6]), x[6])
        u[5] = u[6]  - matrixMultiply(Int32(currentK[5]), x[5])
        u[4] = u[5]  - matrixMultiply(Int32(currentK[4]), x[4])
        u[3] = u[4]  - matrixMultiply(Int32(currentK[3]), x[3])
        u[2] = u[3]  - matrixMultiply(Int32(currentK[2]), x[2])
        u[1] = u[2]  - matrixMultiply(Int32(currentK[1]), x[1])
        u[0] = u[1]  - matrixMultiply(Int32(currentK[0]), x[0])

        // Backward path (delay line update)
        // Note: x[9] = x[8] + ... uses the OLD x[8] value (computed before x[8] is updated)
        let _x9 = x[8] + matrixMultiply(Int32(currentK[8]), u[8])
        let _x8 = x[7] + matrixMultiply(Int32(currentK[7]), u[7])
        let _x7 = x[6] + matrixMultiply(Int32(currentK[6]), u[6])
        let _x6 = x[5] + matrixMultiply(Int32(currentK[5]), u[5])
        let _x5 = x[4] + matrixMultiply(Int32(currentK[4]), u[4])
        let _x4 = x[3] + matrixMultiply(Int32(currentK[3]), u[3])
        let _x3 = x[2] + matrixMultiply(Int32(currentK[2]), u[2])
        let _x2 = x[1] + matrixMultiply(Int32(currentK[1]), u[1])
        let _x1 = x[0] + matrixMultiply(Int32(currentK[0]), u[0])
        x[9] = _x9; x[8] = _x8; x[7] = _x7; x[6] = _x6; x[5] = _x5
        x[4] = _x4; x[3] = _x3; x[2] = _x2; x[1] = _x1
        x[0] = u[0]

        previousEnergy = currentEnergy

        return u[0]
    }

    /// Analog clip circuit emulation.
    /// Ported from tms5220_device::clip_analog()
    @inline(__always)
    private func clipAnalog(_ cliptemp: Int16) -> Int16 {
        var val = Int16(Double(cliptemp) * 1.5)
        if val > 2047 { val = 2047 }
        else if val < -2048 { val = -2048 }
        // Analog pin output with upshift and range adjust
        val &= ~0xF  // mask off low 4 bits
        // output: snnn nnnn NNNN NNNP
        return Int16((Int32(val) << 4) | ((Int32(val) & 0x7F0) >> 3) | ((Int32(val) & 0x400) >> 10))
    }

    /// Generate one 8kHz speech sample.
    /// Ported from tms5220_device::process() (single-sample extraction).
    private func generateSample() -> Int16 {
        // Try to flush pending command
        tryCommand()

        var thisSample: Int32 = 0

        if TALKD {
            // ---- SPEAKING ----

            // Check if we need to load a new frame (IP=0, PC=12, subcycle=1)
            if IP == 0 && PC == 12 && subcycle == 1 {
                // Parse a new frame
                parseFrame()

                // If stop frame, clear TALK and SPEN
                if newFrameStopFlag {
                    TALK = false
                    SPEN = false
                    updateFifoStatusAndInts()
                }

                // Determine interpolation inhibit
                if (!oldFrameUnvoicedFlag && newFrameUnvoicedFlag)
                    || (oldFrameUnvoicedFlag && !newFrameUnvoicedFlag)
                    || (oldFrameSilenceFlag && !newFrameSilenceFlag)
                    || (oldFrameUnvoicedFlag && newFrameSilenceFlag) {
                    inhibit = true
                } else {
                    inhibit = false
                }
            } else {
                // Not a new frame — interpolate existing parameters
                let inhibitState = inhibit && (IP != 0)

                // Updates happen on subcycle 2 (B cycle) only
                if subcycle == 2 {
                    switch PC {
                    case 0:
                        if IP == 0 { pitchZero = false }
                        currentEnergy = Int16(truncatingIfNeeded:
                            Int32(currentEnergy) + ((Int32(coeff.energyTable[newFrameEnergyIdx]) - Int32(currentEnergy)) * (inhibitState ? 0 : 1) >> coeff.interpCoeff[IP])
                        ) * (zpar ? 0 : 1)
                    case 1:
                        currentPitch = Int16(truncatingIfNeeded:
                            Int32(currentPitch) + ((Int32(coeff.pitchTable[newFramePitchIdx]) - Int32(currentPitch)) * (inhibitState ? 0 : 1) >> coeff.interpCoeff[IP])
                        ) * (zpar ? 0 : 1)
                    case 2, 3, 4, 5, 6, 7, 8, 9, 10, 11:
                        let ki = PC - 2
                        let zeroFlag: Bool = ki < 4 ? zpar : uvZpar
                        currentK[ki] = Int16(truncatingIfNeeded:
                            Int32(currentK[ki]) + ((Int32(coeff.kTable[ki][newFrameKIdx[ki]]) - Int32(currentK[ki])) * (inhibitState ? 0 : 1) >> coeff.interpCoeff[IP])
                        ) * (zeroFlag ? 0 : 1)
                    default:
                        break
                    }
                }
            }

            // Generate excitation
            if oldFrameUnvoicedFlag {
                // Unvoiced: use LFSR noise
                if RNG & 1 != 0 {
                    excitationData = ~0x3F  // -64
                } else {
                    excitationData = 0x40   // 64
                }
            } else {
                // Voiced: use chirp table
                if pitchCount >= 51 {
                    excitationData = coeff.chirpTable[51]
                } else {
                    excitationData = coeff.chirpTable[pitchCount]
                }
            }

            // Update LFSR 20 times per sample (once per T cycle)
            for _ in 0..<20 {
                let bitout = ((RNG >> 12) ^ (RNG >> 3) ^ (RNG >> 2) ^ RNG) & 1
                RNG = (RNG << 1) | bitout
            }

            // Execute lattice filter
            thisSample = latticeFilter()

            // Clamp to 14 bits
            if thisSample > 16383 { thisSample = 16383 }
            if thisSample < -16384 { thisSample = -16384 }

            let output = clipAnalog(Int16(thisSample))

            // Update subcycle/PC/IP counters
            subcycle += 1
            if subcycle == 2 && PC == 12 {
                // RESETF3
                if IP == 7 && inhibit { pitchZero = true }
                if IP == 7 {
                    // RESETL4: latch OLDE and OLDP
                    OLDE = newFrameSilenceFlag
                    OLDP = newFrameUnvoicedFlag

                    TALKD = TALK
                    updateFifoStatusAndInts()
                    if !TALK && SPEN { TALK = true }
                }
                subcycle = subcReload
                PC = 0
                IP = (IP + 1) & 0x7
            } else if subcycle == 3 {
                subcycle = subcReload
                PC += 1
            }

            // Advance pitch counter
            pitchCount += 1
            if pitchCount >= Int(currentPitch) || pitchZero {
                pitchCount = 0
            }
            pitchCount &= 0x1FF

            return output
        } else {
            // ---- NOT SPEAKING ----
            // Still advance counters (chip idles but counters run)
            subcycle += 1
            if subcycle == 2 && PC == 12 {
                if IP == 7 {
                    TALKD = TALK
                    updateFifoStatusAndInts()
                    if !TALK && SPEN { TALK = true }
                }
                subcycle = subcReload
                PC = 0
                IP = (IP + 1) & 0x7
            } else if subcycle == 3 {
                subcycle = subcReload
                PC += 1
            }
            return -1  // Chip outputs -1 when idle
        }
    }

    // MARK: - AudioSource

    func fillAudioBuffer(buffer: UnsafeMutableRawPointer, bufferSize: Int, samples: Int) {
        let buf = buffer.bindMemory(to: Int16.self, capacity: samples)

        speechLock.lock()
        defer { speechLock.unlock() }

        // Resample from the 8kHz ring buffer to 44.1kHz output.
        // The ring buffer is filled by operate() on the emulator thread.
        let step = speechSampleRate / outputSampleRate  // ~0.1814
        var lastSample: Int16 = 0

        for i in 0..<samples {
            audioResampleAccum += step
            while audioResampleAccum >= 1.0 {
                audioResampleAccum -= 1.0
                if sampleRingCount > 0 {
                    lastSample = sampleRing[sampleRingTail]
                    sampleRingTail = (sampleRingTail + 1) % Self.sampleRingSize
                    sampleRingCount -= 1
                }
                // If ring empty, hold the last sample (slight glitch is fine)
            }
            buf[i] = lastSample
        }
    }
}
