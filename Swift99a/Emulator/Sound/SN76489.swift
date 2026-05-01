// Swift 99/a
//
// SN76489.swift
// Emulation of the Texas Instruments SN76489 Programmable Sound Generator.
//
// The SN76489 provides:
//   - 3 square wave tone channels with 10-bit frequency dividers
//   - 1 noise channel with a 15-bit LFSR (white or periodic noise)
//   - 4-bit logarithmic volume control per channel (0 = max, 15 = muted)
//   - Clocked at NTSC frequency (3.579545 MHz), divided to audio rate
//
// Audio generation uses Nyquist-filtered sample output and an exponential
// fade-to-zero to reduce DC offset clicks when a channel goes silent.
// Mapped at CPU address 0x8400 (write-only).

import Foundation

/// Logarithmic volume table from SMS Power (maps 4-bit attenuation to amplitude)
private let smsVolumeTable: [Int] = [
    32767, 26028, 20675, 16422, 13045, 10362, 8231, 6538,
    5193, 4125, 3277, 2603, 2067, 1642, 1304, 0
]

private let lfsrReset: UInt16 = 0x4000

/// SN76489/SN76494 Programmable Sound Generator
final class SN76489: Peripheral, AudioSource {
    private let audioLock = NSRecursiveLock()

    // Sound chip state
    private let nClock: Int = 3579545  // NTSC clock
    private var nCounter = [Int](repeating: 0, count: 4)
    private var nNoisePos: Int = 1
    private var lfsr: UInt16 = lfsrReset
    private var nRegister = [Int](repeating: 0, count: 4)
    private var nVolume = [Int](repeating: 0xF, count: 4)  // 0xF = muted
    private var nFade = [Double](repeating: 1.0, count: 4)
    private var nOutput = [Double](repeating: 1.0, count: 4)
    private var nVolumeTable = [Double](repeating: 0, count: 16)
    private let fadeClkTick: Double = 0.001 / 9.0
    private var latchByte: Int = 0
    private let nTappedBits: Int = 0x0003
    private let audioSampleRate: Int = 44100

    /// Exact internal-clock-ticks per output sample. The SN76489 input clock
    /// is divided by 16 before driving the tone counters, so at NTSC speed
    /// this is 3 579 545 / 16 / 44 100 ≈ 5.0731. Rounding this to an integer
    /// (5) every sample makes the chip run ~1.4 % slow — every tone plays
    /// flat. Instead we use a persistent fractional accumulator: each sample
    /// pulls `floor(accumulator)` clocks and the residual carries forward.
    private let clocksPerSampleExact: Double = 3_579_545.0 / 16.0 / 44_100.0
    private var clockAccum: Double = 0

    /// Tone register values at or below this threshold sit above Nyquist
    /// at the current sample rate and must be silenced to avoid aliasing.
    /// (Tone Hz = 111 860 / nRegister; threshold = 111 860 / (sampleRate/2).)
    private let nyquistRegisterThreshold: Int = Int(111_860.0 / (44_100.0 / 2.0))

    override init(core: EmulatorSystem?) {
        super.init(core: core)
        nCounter[3] = 1
        soundInit()
    }

    private func soundInit() {
        for i in 0..<16 {
            nVolumeTable[i] = Double(smsVolumeTable[i]) / 34949.3333
        }
    }

    private func parity(_ val: Int) -> Int {
        var v = val
        v ^= v >> 8
        v ^= v >> 4
        v ^= v >> 2
        v ^= v >> 1
        return v & 1
    }

    private func resetNoise() {
        lfsr = lfsrReset
        switch nRegister[3] & 0x03 {
        case 0: nCounter[3] = 0x10
        case 1: nCounter[3] = 0x20
        case 2: nCounter[3] = 0x40
        case 3: nCounter[3] = nRegister[2] != 0 ? nRegister[2] : 0x400
        default: break
        }
    }

    // MARK: - AudioSource

    func fillAudioBuffer(buffer: UnsafeMutableRawPointer, bufferSize: Int, samples: Int) {
        let buf = buffer.bindMemory(to: Int16.self, capacity: samples)
        var remaining = samples

        var sampleIndex = 0
        while remaining > 0 {
            // Pull the integer number of internal clocks owed for this sample
            // from the fractional accumulator. Over time this averages to
            // clocksPerSampleExact (~5.0731) instead of the constant 5 the
            // old code used, eliminating the 1.4% pitch flatness.
            clockAccum += clocksPerSampleExact
            let nClocksPerSample = Int(clockAccum)
            clockAccum -= Double(nClocksPerSample)

            // Emulate drift to zero
            for idx in 0..<4 {
                if nFade[idx] > 0.0 {
                    nFade[idx] -= fadeClkTick * Double(nClocksPerSample)
                    if nFade[idx] < 0.0 { nFade[idx] = 0.0 }
                }
            }

            // Tone channels
            for idx in 0..<3 {
                nCounter[idx] -= nClocksPerSample
                while nCounter[idx] <= 0 {
                    nCounter[idx] += nRegister[idx] != 0 ? nRegister[idx] : 0x400
                    nOutput[idx] *= -1.0
                    nFade[idx] = 1.0
                }
                // Mute frequencies above Nyquist
                if nRegister[idx] != 0 && nRegister[idx] <= nyquistRegisterThreshold {
                    nFade[idx] = 0.0
                }
            }

            // Noise channel
            nCounter[3] -= nClocksPerSample
            while nCounter[3] <= 0 {
                switch nRegister[3] & 0x03 {
                case 0: nCounter[3] += 0x10
                case 1: nCounter[3] += 0x20
                case 2: nCounter[3] += 0x40
                case 3: nCounter[3] += nRegister[2] != 0 ? nRegister[2] : 0x400
                default: break
                }
                nNoisePos *= -1
                let oldOut = nOutput[3]

                if nNoisePos > 0 {
                    var inBit: UInt16 = 0
                    if nRegister[3] & 0x4 != 0 {
                        // White noise
                        if parity(Int(lfsr) & nTappedBits) != 0 { inBit = 0x4000 }
                        if lfsr & 0x01 != 0 {
                            if nOutput[3] == 0.0 {
                                nOutput[3] = 1.0
                            } else {
                                nOutput[3] *= -1.0
                            }
                        }
                    } else {
                        // Periodic noise
                        if lfsr & 0x0001 != 0 {
                            inBit = 0x4000
                            nOutput[3] = 1.0
                        } else {
                            nOutput[3] = 0.0
                        }
                    }
                    lfsr >>= 1
                    lfsr |= inBit
                }
                if oldOut != nOutput[3] { nFade[3] = 1.0 }
            }

            // Mix and output
            var output = nOutput[0] * nVolumeTable[nVolume[0]] * nFade[0]
                + nOutput[1] * nVolumeTable[nVolume[1]] * nFade[1]
                + nOutput[2] * nVolumeTable[nVolume[2]] * nFade[2]
                + nOutput[3] * nVolumeTable[nVolume[3]] * nFade[3]
            output /= 4.0

            buf[sampleIndex] = Int16(clamping: Int(32767.0 * output))
            sampleIndex += 1
            remaining -= 1
        }
    }

    // MARK: - Peripheral

    override func write(addr: Int, isIO: Bool, cycles: inout Int, accessType: MemoryAccess, data: UInt8) {
        if accessType != .free {
            cycles += 28  // Sound chip hold time
        }

        let d = Int(data)
        if d & 0x80 != 0 { latchByte = d }

        switch d & 0xF0 {
        case 0x90, 0xB0, 0xD0, 0xF0:
            // Volume
            nVolume[(d & 0x60) >> 5] = d & 0xF
        case 0xE0:
            // Noise control
            nRegister[3] = d & 0x07
            resetNoise()
        default:
            let chan = (latchByte & 0x60) >> 5
            if d & 0x80 != 0 {
                // Latch write - low 4 bits of tone
                nRegister[chan] = (nRegister[chan] & 0xFFF0) | (d & 0x0F)
            } else {
                if latchByte & 0x10 != 0 {
                    nVolume[chan] = d & 0xF
                } else if chan == 3 {
                    nRegister[3] = d & 0x07
                    resetNoise()
                } else {
                    nRegister[chan] = (nRegister[chan] & 0xF) | ((d & 0x3F) << 4)
                }
            }
        }
    }

    override func initialize(index: Int) -> Bool {
        setIndex(name: "SN76489", index: index)
        soundInit()

        // Connect to the audio engine
        theCore?.audioEngine?.setAudioSource(self)

        return true
    }
}
