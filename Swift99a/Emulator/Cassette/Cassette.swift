// Swift 99/a
//
// Cassette.swift
// Emulated cassette tape interface for the TI-99/4A.
//
// On real hardware the cassette is not a peripheral card — it lives on the
// TMS9901 PSI as five CRU bits (Nouspikel):
//
//     bit 22 (write)  Motor #1 (CS1)
//     bit 23 (write)  Motor #2 (CS2)
//     bit 24 (write)  Audio gate (1 = silence tape input through speaker)
//     bit 25 (write)  Data output to tape (CDOC)
//     bit 27 (read)   Data input from CS1 (CDIN)
//
// This device follows the Classic99 model: the loaded tape is stored as a
// flat 8-bit unsigned PCM buffer at 16 kHz. The CDIN bit is just a threshold
// of the current sample, and the same samples are mixed into the speaker
// when motor + audio gate are open. WAV recordings of real TI tapes drop in
// directly; `.titape` containers have their bit stream resynthesised into
// the equivalent PCM at load time inside CassetteImage.

import Foundation

/// User-controlled transport state. On real hardware the cassette mechanism
/// only engages when the user has physically pressed PLAY (or RECORD) on the
/// deck — the CPU's motor signal is the second gate, not the only one.
enum CassetteTransportState {
    case stopped
    case play
}

final class Cassette: AudioSource {

    // MARK: - Configuration

    /// Sample rate of the internal PCM buffer.
    private static let sampleRate: Double = CassetteImage.pcmSampleRate

    /// Threshold for converting a PCM byte to a CDIN bit. Matches
    /// Classic99's tape.cpp `cutoff = 0x12`. The cassette image stores
    /// half-wave-rectified, auto-levelled audio (mean ≈ 29) for both
    /// loaded WAVs and synthesised TITape, so anything ≥ 0x12 is a peak
    /// at a flux transition. The active-low inversion happens in
    /// `readDataIn()` after this threshold check.
    private static let cdinThreshold: UInt8 = 0x12

    /// CPU clock in MHz; cycles ÷ this = microseconds.
    private static let cpuMHz: Double = 3.0

    /// Cassette output amplitude relative to Int16 full scale (~2.5%).
    private static let outputAmplitude: Float = 819

    /// TEMP: enables verbose console logging while the cassette path is
    /// still being shaken down.
    private static let debugLog: Bool = true

    /// Banner printed once when the device is constructed, so we can tell
    /// from the log which build of the cassette code is running.
    private static let buildTag: String = {
        let s = "[Cassette] build = TMS9901 claims ALL bit writes 0-15 (cassette ack + timer load now reach the chip)"
        print(s)
        return s
    }()

    // MARK: - Wiring

    /// The TMS9901 owns the motor / audio-gate / CDOC flag state.
    weak var tms9901: TMS9901?

    /// CPU reference. Used to derive a sub-microsecond timestamp from
    /// `totalCycleCount` so CDIN reads index into the PCM buffer at the
    /// *current* CPU instruction, not at the end of the last emulator tick.
    weak var cpu: TMS9900?

    // MARK: - State

    private(set) var currentImage: CassetteImage?

    /// 8-bit unsigned PCM (16 kHz mono). Populated from the loaded image.
    private var pcm: [UInt8] = []

    /// Audio playback head, advanced per audio sample at 44.1 kHz inside
    /// `fillAudioBuffer`. Independent from the CDIN side so the audio thread
    /// doesn't need to coordinate with the emulator thread on every fill.
    private var audioSampleCursor: Double = 0

    /// PCM-sample index at which the tape was when the motor most recently
    /// stopped (or at load time, 0). Combined with `motorOnCycles` and the
    /// CPU's current cycle count, this gives an instantaneous CDIN sample
    /// position at any time.
    private var sampleAtMotorOn: Int = 0

    /// CPU cycle count snapshot taken when the motor most recently came on
    /// while transport is in PLAY. `nil` when the tape isn't moving.
    private var motorOnCycles: Int?

    /// User-side transport state. Defaults to `.stopped` — the user must
    /// press PLAY in the cassette transport UI before the tape moves.
    private(set) var transportState: CassetteTransportState = .stopped

    /// Current playback progress as a value in 0...1. Exposed for the
    /// transport UI's position bar.
    var progress: Double {
        guard !pcm.isEmpty else { return 0 }
        return min(1, max(0, audioSampleCursor / Double(pcm.count)))
    }

    /// CDIN read counter — debug only, used to throttle log output.
    private var cdinReadCount: Int = 0

    /// Last emulator timestamp at which we logged the CPU PC during motor-on.
    private var lastPCLogTimestamp: Double = 0

    // MARK: - Transport control

    func play() {
        transportState = .play
        if Self.debugLog { print("[Cassette] TRANSPORT: PLAY") }
    }
    func stop() {
        transportState = .stopped
        if Self.debugLog { print("[Cassette] TRANSPORT: STOP") }
    }
    func rewind() {
        sampleAtMotorOn = 0
        audioSampleCursor = 0
        if motorOnCycles != nil {
            motorOnCycles = cpu?.totalCycleCount
        }
    }

    // MARK: - Image lifecycle

    func load(image: CassetteImage) {
        currentImage = image
        pcm = image.pcm
        sampleAtMotorOn = 0
        audioSampleCursor = 0
        motorOnCycles = nil
        transportState = .stopped
        cdinReadCount = 0
        if Self.debugLog {
            _ = Self.buildTag
            let firstSamples = pcm.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("[Cassette] LOAD \(image.displayName) (source=\(image.source)): " +
                  "samples=\(pcm.count) (\(String(format: "%.1f", image.durationSeconds)) s), " +
                  "first=\(firstSamples)")
        }
        // [trace] mirror Classic99 LOAD event with the first 16 samples so
        // the diff has equivalent inputs at the start of each trace.
        let cyc = cpu?.totalCycleCount ?? 0
        CassetteTrace.openIfNeeded(currentCycle: cyc)
        let first16 = pcm.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        CassetteTrace.log(currentCycle: cyc, event: "LOAD",
                          details: "size=\(pcm.count) first=\(first16)")
    }

    func eject() {
        currentImage = nil
        pcm = []
        sampleAtMotorOn = 0
        audioSampleCursor = 0
        motorOnCycles = nil
        transportState = .stopped
    }

    var isLoaded: Bool { currentImage != nil }

    // MARK: - Emulation tick

    /// Detects motor-on / motor-off transitions and pivots the CDIN time
    /// baseline accordingly. The actual sample-position computation happens
    /// lazily inside `currentSampleIndex()` so each CDIN read reflects the
    /// tape position at the *current* CPU instruction.
    func operate(timestamp: Double) {
        let motorRunning = !pcm.isEmpty
            && transportState == .play
            && (tms9901?.cs1MotorOn ?? false)

        if motorRunning, motorOnCycles == nil {
            motorOnCycles = cpu?.totalCycleCount ?? 0
            if Self.debugLog {
                print("[Cassette] MOTOR ON  @cycle \(motorOnCycles!), startSample=\(sampleAtMotorOn)")
            }
            // [trace] this is the off→on transition that ungates the
            // decoder. Reset the trace clock and log a MOTOR event matching
            // Classic99's setTapeMotor format.
            CassetteTrace.resetClock(currentCycle: motorOnCycles!)
            CassetteTrace.log(currentCycle: motorOnCycles!, event: "MOTOR",
                              details: "req=1 prevOn=0 state=1 pos=\(sampleAtMotorOn) size=\(pcm.count)")
        } else if !motorRunning, let onCycles = motorOnCycles {
            let elapsedCycles = (cpu?.totalCycleCount ?? onCycles) - onCycles
            let elapsedMicros = Double(elapsedCycles) / Self.cpuMHz
            let advance = Int(elapsedMicros * Self.sampleRate / 1_000_000)
            sampleAtMotorOn = min(sampleAtMotorOn + advance, pcm.count)
            motorOnCycles = nil
            if Self.debugLog {
                print("[Cassette] MOTOR OFF +\(elapsedCycles) cyc " +
                      "(\(String(format: "%.1f", elapsedMicros)) µs), sample=\(sampleAtMotorOn)")
            }
        }

        // Once-per-second PC dump while motor is on (kept for diagnostics).
        if Self.debugLog, motorOnCycles != nil, let cpu = cpu, let core = tms9901?.theCore,
           timestamp - lastPCLogTimestamp >= 1_000_000 {
            lastPCLogTimestamp = timestamp
            func reg(_ n: Int) -> UInt16 {
                let a = Int(cpu.WP) + (n * 2)
                let hi = core.peekMemoryByte(address: a)
                let lo = core.peekMemoryByte(address: a + 1)
                return (UInt16(hi) << 8) | UInt16(lo)
            }
            let pos = currentSampleIndex()
            print(String(format:
                "[Cassette] tick PC=>%04X WP=>%04X R0=%04X R1=%04X R2=%04X R3=%04X R7=%04X R8=%04X R10=>%04X | sample=%d/%d",
                cpu.PC, cpu.WP, reg(0), reg(1), reg(2), reg(3), reg(7), reg(8), reg(10), pos, pcm.count))
        }
    }

    // MARK: - CDIN

    /// Returns the value of TMS9901 bit 27 — the cassette data input.
    ///
    /// **Active-low.** On real TI-99/4A hardware, CDIN reads 0 when a tape
    /// peak is present (sample above threshold) and 1 when the signal is
    /// silent. Classic99's tape.cpp does the same inversion at CRU read
    /// time. Without this inversion, every spin-loop in the cassette ISR
    /// hangs because the ROM's "wait for next peak" loop reads "peak" all
    /// the time during silence (and vice-versa).
    ///
    /// When no tape is loaded or the transport is stopped, the line floats
    /// idle (no peak ever) — return 1, the documented inactive level.
    func readDataIn() -> UInt8 {
        guard !pcm.isEmpty, transportState == .play else { return 1 }
        let pos = currentSampleIndex()
        guard pos < pcm.count else { return 1 }
        let peak = pcm[pos] >= Self.cdinThreshold
        let val: UInt8 = peak ? 0 : 1
        // [trace] log every CDIN read in the same format as Classic99's
        // tape.cpp::getTapeBit() hook. Note: bit values are inverted
        // relative to Classic99 because Classic99 logs `getTapeBit()`'s
        // raw return BEFORE the active-low inversion happens at CRU read
        // time. Here we log the post-inversion value (what the ROM sees),
        // which matches Classic99's `bit=` (which is also post-getTapeBit
        // semantically — both represent "is there a peak").
        // To make the bit values directly comparable to Classic99, we log
        // peak (1=peak, 0=silent), matching `bit=` in the C99 trace.
        let bitVal: Int = peak ? 1 : 0
        let sampleVal = Int(pcm[pos])
        let cyc = cpu?.totalCycleCount ?? 0
        CassetteTrace.log(currentCycle: cyc, event: "CDIN",
                          details: "pos=\(pos) sample=\(sampleVal) bit=\(bitVal) motor=\(transportState == .play ? 1 : 0)")
        if Self.debugLog {
            cdinReadCount += 1
            if cdinReadCount <= 5 || cdinReadCount % 250_000 == 0 {
                print("[Cassette] CDIN[\(cdinReadCount)] sample[\(pos)]=" +
                      "\(String(format: "%02X", pcm[pos])) val=\(val)")
            }
        }
        return val
    }

    private func currentSampleIndex() -> Int {
        var pos = sampleAtMotorOn
        if let onCycles = motorOnCycles, let cpu = cpu {
            let elapsedCycles = cpu.totalCycleCount - onCycles
            let elapsedMicros = Double(elapsedCycles) / Self.cpuMHz
            pos += Int(elapsedMicros * Self.sampleRate / 1_000_000)
        }
        return min(pos, pcm.count)
    }

    // MARK: - AudioSource

    func fillAudioBuffer(buffer: UnsafeMutableRawPointer, bufferSize: Int, samples: Int) {
        let int16Buffer = buffer.bindMemory(to: Int16.self, capacity: samples)

        guard !pcm.isEmpty, let tms = tms9901 else {
            for i in 0..<samples { int16Buffer[i] = 0 }
            return
        }

        let motorOn = tms.cs1MotorOn || tms.cs2MotorOn
        let gateOpen = !tms.cassetteAudioGateClosed
        let playing = transportState == .play
        let bitsRemaining = audioSampleCursor < Double(pcm.count)

        guard playing && motorOn && gateOpen && bitsRemaining else {
            for i in 0..<samples { int16Buffer[i] = 0 }
            return
        }

        let audioOutRate: Double = 44100
        let advancePerSample = Self.sampleRate / audioOutRate  // 16000 / 44100 ≈ 0.363
        let amp = Self.outputAmplitude
        let endPos = Double(pcm.count)

        for i in 0..<samples {
            if audioSampleCursor >= endPos {
                int16Buffer[i] = 0
            } else {
                let idx = Int(audioSampleCursor)
                let s = pcm[idx]
                // Map 0…255 → -amp…+amp around 0x80.
                let centred = Float(Int(s) - 0x80) / 128.0  // -1…+1
                int16Buffer[i] = Int16(centred * amp)
                audioSampleCursor += advancePerSample
            }
        }
    }
}
