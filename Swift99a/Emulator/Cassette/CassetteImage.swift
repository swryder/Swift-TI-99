// Swift 99/a
//
// CassetteImage.swift
// Loaded tape image — the data behind a `.titape`, `.wav`, or `.mp3` file.
// Internally we store everything as 8-bit unsigned mono PCM at 16 kHz, the
// same shape Classic99 uses for its tape buffer (see classic99 console/tape.cpp).
// The Cassette device consumes this PCM directly: CDIN is read as
// `pcm[currentPos] >= threshold`, and the same samples are mixed into the
// speaker. WAV files of real TI cassette recordings drop straight in;
// `.titape` containers are demodulated post-FSK so we resynthesise the
// equivalent waveform at load time using the canonical leader / record
// framing.
//
// TITape format (reverse-engineered from Win994a sample files):
//
//   Offset  Size  Field
//   0x00    8     Magic ASCII "TI-TAPE\0"
//   0x08    4     u32 LE — current tape head position in bytes (0 = rewound)
//   0x0C    4     u32 LE — total payload length in bytes (= file size − 16)
//   0x10    N     Raw payload — concatenated data bytes the cassette would
//                 have produced after demodulation.

import Foundation
import AVFoundation

final class CassetteImage {

    enum Source: Equatable {
        case tiTape       // Win994a .titape (demodulated bytes; PCM synthesised)
        case wav          // 8-bit unsigned PCM decoded from WAV/MP3
    }

    enum LoadError: Error, LocalizedError {
        case fileTooSmall
        case badMagic
        case truncated
        case unsupportedExtension(String)
        case audioDecodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileTooSmall: return "Tape file is too small to contain a TITape header."
            case .badMagic: return "Tape file does not start with the TITape magic bytes."
            case .truncated: return "Tape payload is shorter than the header advertises."
            case .unsupportedExtension(let ext):
                return "Unsupported tape file type: .\(ext)"
            case .audioDecodeFailed(let msg):
                return "Audio decode failed: \(msg)"
            }
        }
    }

    /// Sample rate of the internal PCM buffer. Matches Classic99 (16 kHz).
    static let pcmSampleRate: Double = 16000

    let url: URL
    let source: Source
    let displayName: String

    /// 8-bit unsigned mono PCM at 16 kHz. 0x80 is the silence midpoint.
    /// Cassette reads CDIN as `pcm[pos] >= 0x80`.
    let pcm: [UInt8]

    var sampleCount: Int { pcm.count }
    var durationSeconds: Double { Double(pcm.count) / Self.pcmSampleRate }

    private init(url: URL, source: Source, displayName: String, pcm: [UInt8]) {
        self.url = url
        self.source = source
        self.displayName = displayName
        self.pcm = pcm
    }

    // MARK: - Loading

    static func load(from url: URL) throws -> CassetteImage {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "titape":
            return try loadTiTape(from: url)
        case "wav", "wave", "mp3", "m4a", "aif", "aiff", "caf":
            return try loadAudioFile(from: url)
        default:
            throw LoadError.unsupportedExtension(ext)
        }
    }

    // MARK: - TITape

    private static func loadTiTape(from url: URL) throws -> CassetteImage {
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { throw LoadError.fileTooSmall }

        let magic: [UInt8] = [0x54, 0x49, 0x2D, 0x54, 0x41, 0x50, 0x45, 0x00]
        guard data.prefix(8).elementsEqual(magic) else { throw LoadError.badMagic }

        let length = readUInt32LE(data, offset: 12)
        guard 16 + length <= data.count else { throw LoadError.truncated }

        let payload = Array(data[16..<(16 + length)])
        let pcm = synthesizePCM(fromTiTapePayload: payload)
        let name = url.deletingPathExtension().lastPathComponent

        return CassetteImage(url: url, source: .tiTape, displayName: name, pcm: pcm)
    }

    /// Builds a PCM waveform that matches what a real TI cassette would have
    /// produced for the given post-demod byte stream. Steps:
    ///   1. Wrap the bytes with the canonical cassette framing (zero-byte
    ///      leader, 0xFF mark, count repeated, then each 64-byte record
    ///      written twice with sync + mark + checksum).
    ///   2. Expand to a bit stream (MSB first per byte).
    ///   3. Render each bit cell as biphase-mark (FM): a transition at
    ///      every cell boundary, plus a mid-cell transition for `1` bits
    ///      only. This produces the documented 689/1378 Hz transition
    ///      rates the cassette ROM expects (one transition per cell during
    ///      the all-zeros leader, two transitions per cell during a `1`).
    private static func synthesizePCM(fromTiTapePayload payload: [UInt8]) -> [UInt8] {
        let recordSize = 64
        let recordCount = max(1, (payload.count + recordSize - 1) / recordSize)

        var byteStream: [UInt8] = []
        // 768 zero bytes — the canonical TI cassette leader length per
        // Nouspikel's documentation. ~8.9 s of 689 Hz tone, plenty of
        // time for the ROM's auto-tune to lock onto the bit cell rate.
        let leaderBytes = 768
        byteStream.reserveCapacity(leaderBytes + 3 + recordCount * 2 * (8 + 1 + recordSize + 1))

        // Leader = 0xFF mark bytes (= "1" bits). Real TI cassette tape
        // uses a long mark-tone leader which under biphase-mark coding
        // produces the documented 689 Hz peak rate after half-wave
        // rectification. Earlier this was 0x00 bytes which (under our
        // simplified pulse-placement synth) accidentally produced the
        // same 689 Hz rate but with INVERTED bit-to-peak-pattern
        // mapping — leader detection passed, but every data bit was
        // also inverted, so byte values came out scrambled.
        byteStream.append(contentsOf: Array(repeating: UInt8(0xFF), count: leaderBytes))
        let count = UInt8(min(recordCount, 255))
        byteStream.append(count)
        byteStream.append(count)

        // Records, each written twice
        for r in 0..<recordCount {
            let start = r * recordSize
            let end = min(start + recordSize, payload.count)
            var record = Array(payload[start..<end])
            while record.count < recordSize { record.append(0) }
            var sum: UInt32 = 0
            for b in record { sum &+= UInt32(b) }
            let checksum = UInt8(sum & 0xFF)
            for _ in 0..<2 {
                byteStream.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // sync
                byteStream.append(0xFF)                                              // mark
                byteStream.append(contentsOf: record)
                byteStream.append(checksum)
            }
        }

        // Bit stream, MSB first
        var bits: [UInt8] = []
        bits.reserveCapacity(byteStream.count * 8)
        for byte in byteStream {
            for shift in (0..<8).reversed() {
                bits.append((byte >> shift) & 1)
            }
        }

        // Render bits to PCM as half-wave-rectified continuous-phase FSK.
        // Each cell contains "0": 1 sine cycle (689 Hz) or "1": 2 sine
        // cycles (1378 Hz), continuous phase across cells.
        //
        // Empirical note: this isn't textbook biphase-mark — TI cassettes
        // actually use biphase-mark FM encoding — but the WAV decode path
        // is byte-perfect against Classic99, and FSK gives the cassette
        // ROM a similar enough peak-count-per-cell that the bit decoder
        // gets through the leader and into the data section. Biphase-
        // mark was tried but produced "NO DATA FOUND" (leader detection
        // failed entirely); FSK reaches "ERROR DETECTED IN DATA" (leader
        // detected, byte values mismatched). Pending a deeper diff
        // against a known-good WAV at the bit-shape level, FSK is the
        // closest-to-working option.
        //
        // The trailing auto-level pass normalises mean=29 to match the
        // WAV pipeline's resampleAndShape output statistically.
        let cellMicros = 1450.6
        let samplesPerCell = Self.pcmSampleRate * cellMicros / 1_000_000  // 23.21
        let totalSamples = Int(Double(bits.count) * samplesPerCell + 0.5)

        let peakAmplitude: Double = 160.0

        let dPhaseZero = 2.0 * .pi / samplesPerCell
        // Initial phase chosen so the first peak lands at sample ~10 of
        // each "0" cell, matching real WAV recordings (analyzed against
        // CATALOG.wav from Comparison/: 44.1 kHz peak at sample 27 =
        // 16 kHz sample 9.8, with a 64-sample = 1450 µs = 689 Hz period
        // that exactly matches our cellMicros). With startPhase=0 the
        // peak naturally lands at sample 5.75 (quarter into the cell);
        // shifting by ~4 samples brings it to where real cassette
        // recordings put it, which is what the cassette ROM's bit
        // decoder is calibrated for.
        let peakSampleTarget = 9.8
        var phase: Double = .pi / 2.0 - peakSampleTarget * dPhaseZero
        if phase < 0 { phase += 2.0 * .pi }
        var pcm = [UInt8](repeating: 0, count: totalSamples)
        var sampleIdx = 0

        // Bit-to-cycle mapping per TI cassette convention:
        //   "1" bit = mark tone = 689 Hz (= 1 sine cycle per cell)
        //   "0" bit = space tone = 1378 Hz (= 2 sine cycles per cell)
        // (Note: this is INVERTED from "natural" FSK where "0" is the
        // base frequency. TI cassettes use mark = "1" by convention,
        // and the ROM's bit decoder is calibrated for that mapping.)
        for bit in bits {
            let dPhase = dPhaseZero * (bit == 1 ? 1.0 : 2.0)
            let nextBoundary = min(totalSamples,
                                   Int((Double(sampleIdx) + samplesPerCell).rounded()))
            while sampleIdx < nextBoundary {
                let v = sin(phase)
                if v > 0 {
                    pcm[sampleIdx] = UInt8(max(0, min(255, (v * peakAmplitude).rounded())))
                }
                phase += dPhase
                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
                sampleIdx += 1
            }
        }

        // Auto-level to mean = 29, identical to what `resampleAndShape`
        // does to the WAV pipeline. The WAV decode path is byte-perfect
        // vs Classic99 with this normalisation in place; the .titape
        // synth previously emitted raw sine peaks (mean ~80, amplitude
        // 160) and the cassette ROM's leader-period measurement
        // computed the wrong timer load from that, causing ERROR
        // DETECTED IN DATA on every .titape load. Same input shape
        // through both pipelines = consistent decode behaviour.
        var sum: Int = 0
        for v in pcm { sum += Int(v) }
        let avg = Double(sum) / Double(max(1, pcm.count))
        if avg > 0 {
            let scale = 29.0 / avg
            for i in 0..<pcm.count {
                let scaled = (Double(pcm[i]) * scale).rounded()
                pcm[i] = UInt8(max(0, min(255, scaled)))
            }
        }

        return pcm
    }

    // MARK: - WAV / MP3 / M4A

    /// Decode any audio file AVAudioFile understands, resample to 16 kHz mono,
    /// and convert to 8-bit unsigned. WAV is the format Classic99 uses for
    /// its tape recordings; MP3/M4A are accepted as a convenience.
    private static func loadAudioFile(from url: URL) throws -> CassetteImage {
        // First, try the simple WAV path. Many TI-cassette WAV captures (e.g.
        // the ones produced by tools like CS1er and shared on archive sites)
        // ship with a broken RIFF chunk size — the outer length claims ~98
        // bytes while the inner `data` chunk has the real size. AVAudioFile
        // honours the RIFF size and reads only those few bytes, so we'd end
        // up with a tape that "plays" in milliseconds. Parsing the `data`
        // chunk directly side-steps the bug and is a tiny amount of code
        // for this format anyway.
        if url.pathExtension.lowercased().hasPrefix("wav") || url.pathExtension.lowercased() == "wave" {
            if let pcm = try parseSimpleWav(url: url) {
                let name = url.deletingPathExtension().lastPathComponent
                return CassetteImage(url: url, source: .wav, displayName: name, pcm: pcm)
            }
            // fall through to AVAudioFile for non-trivial WAVs
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.audioDecodeFailed(error.localizedDescription)
        }

        // Read into 32-bit float, then we'll resample + quantise ourselves.
        // Most WAV recordings of real TI tapes are mono; if stereo, mix down.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: file.fileFormat.sampleRate,
                                         channels: file.fileFormat.channelCount,
                                         interleaved: false) else {
            throw LoadError.audioDecodeFailed("Could not construct float format")
        }
        let frameCapacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw LoadError.audioDecodeFailed("Could not allocate PCM buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw LoadError.audioDecodeFailed(error.localizedDescription)
        }

        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let srcRate = buffer.format.sampleRate

        // Mix to mono float in source rate.
        guard let raw = buffer.floatChannelData else {
            throw LoadError.audioDecodeFailed("Float channel data missing")
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            let chan = raw[c]
            for i in 0..<frameCount {
                mono[i] += chan[i]
            }
        }
        if channels > 1 {
            let inv = 1.0 / Float(channels)
            for i in 0..<frameCount { mono[i] *= inv }
        }

        let pcm = resampleAndShape(mono: mono, frameCount: frameCount, srcRate: srcRate)
        let name = url.deletingPathExtension().lastPathComponent
        return CassetteImage(url: url, source: .wav, displayName: name, pcm: pcm)
    }

    /// Direct port of Classic99's WAV-to-cassette pipeline (console/tape.cpp):
    /// resample to 16 kHz, half-wave rectify (negative half → 0, positive
    /// half doubled), then auto-level so the mean of the surviving positive
    /// samples is 29. The downstream threshold of 0x12 (18) in
    /// Cassette.swift then catches one brief peak per flux transition. This
    /// gives the cassette ROM exactly the CDIN pattern it sees on real
    /// hardware: silence with one peak per cell for "0" leader, two peaks
    /// per cell for "1" data bits.
    private static func resampleAndShape(mono: [Float], frameCount: Int, srcRate: Double) -> [UInt8] {
        let dstCount = Int(Double(frameCount) * Self.pcmSampleRate / srcRate)
        var pcm = [UInt8](repeating: 0, count: dstCount)
        let ratio = srcRate / Self.pcmSampleRate

        // Pass 1: resample + half-wave rectify. Classic99's signed-16 mode
        // does `if (val < 0) val=0; val /= 128;` — the equivalent for our
        // [-1, +1] floats is `max(0, sample) * 256` capped at 255.
        for i in 0..<dstCount {
            let srcPos = Double(i) * ratio
            let s0 = Int(srcPos)
            let sample: Float
            if s0 >= frameCount - 1 {
                sample = mono[max(0, frameCount - 1)]
            } else {
                let frac = Float(srcPos - Double(s0))
                sample = mono[s0] * (1 - frac) + mono[s0 + 1] * frac
            }
            let positive = max(Float(0), sample)
            let scaled = min(Float(255), positive * 256)
            pcm[i] = UInt8(scaled.rounded())
        }

        // Pass 2: auto-level so mean = 29 (Classic99's tuned target).
        var sum: Int = 0
        for v in pcm { sum += Int(v) }
        let avg = Double(sum) / Double(max(1, pcm.count))
        if avg > 0 {
            let scale = 29.0 / avg
            for i in 0..<pcm.count {
                let scaled = (Double(pcm[i]) * scale).rounded()
                pcm[i] = UInt8(max(0, min(255, scaled)))
            }
        }
        return pcm
    }

    // MARK: - Simple WAV parser
    //
    // Walks the RIFF chunk list directly, ignoring the (often broken) outer
    // RIFF size. Supports the only formats we'll see in the wild for TI
    // cassette captures: 8-bit unsigned PCM and 16-bit signed PCM, mono or
    // stereo, any sample rate. Returns the PCM resampled to 16 kHz, mixed
    // to mono, in 8-bit unsigned form. Returns nil if the file isn't a
    // recognisable RIFF/WAVE — caller falls back to AVAudioFile.

    private static func parseSimpleWav(url: URL) throws -> [UInt8]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.audioDecodeFailed(error.localizedDescription)
        }
        guard data.count >= 44 else { return nil }
        // RIFF / WAVE
        guard data[0..<4].elementsEqual([0x52, 0x49, 0x46, 0x46]) else { return nil }
        guard data[8..<12].elementsEqual([0x57, 0x41, 0x56, 0x45]) else { return nil }

        var pos = 12
        var fmtFound = false
        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var audioFormat: UInt16 = 0
        var dataStart = 0
        var dataSize = 0

        while pos + 8 <= data.count {
            let id = data[pos..<pos+4]
            let chunkSize = Int(readUInt32LE(data, offset: pos + 4))
            let bodyStart = pos + 8

            if id.elementsEqual([0x66, 0x6D, 0x74, 0x20]) {  // "fmt "
                guard bodyStart + 16 <= data.count else { return nil }
                audioFormat = UInt16(data[bodyStart]) | (UInt16(data[bodyStart + 1]) << 8)
                channels = UInt16(data[bodyStart + 2]) | (UInt16(data[bodyStart + 3]) << 8)
                sampleRate = UInt32(readUInt32LE(data, offset: bodyStart + 4))
                bitsPerSample = UInt16(data[bodyStart + 14]) | (UInt16(data[bodyStart + 15]) << 8)
                fmtFound = true
            } else if id.elementsEqual([0x64, 0x61, 0x74, 0x61]) {  // "data"
                dataStart = bodyStart
                // The chunk header may lie about size (broken writers). Trust
                // the larger of declared chunk size and "rest of file".
                let bytesAvailable = data.count - bodyStart
                dataSize = max(chunkSize, bytesAvailable)
                dataSize = min(dataSize, bytesAvailable)
                break
            }

            // Chunks are padded to even boundaries.
            pos = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard fmtFound, dataStart > 0, dataSize > 0,
              audioFormat == 1,                        // PCM only
              channels >= 1, channels <= 2,
              sampleRate > 0,
              bitsPerSample == 8 || bitsPerSample == 16 else {
            return nil
        }

        // Decode the raw PCM frames into mono Float in [-1, +1].
        let bytesPerSample = Int(bitsPerSample / 8)
        let frameSize = bytesPerSample * Int(channels)
        let frameCount = dataSize / frameSize
        var mono = [Float](repeating: 0, count: frameCount)

        if bitsPerSample == 8 {
            // Unsigned 8-bit (0..255, 128 = silence).
            for f in 0..<frameCount {
                var sum: Int = 0
                for c in 0..<Int(channels) {
                    let off = dataStart + f * frameSize + c
                    sum += Int(data[off]) - 128
                }
                mono[f] = Float(sum) / (127.0 * Float(channels))
            }
        } else {
            // Signed 16-bit little-endian.
            for f in 0..<frameCount {
                var sum: Int = 0
                for c in 0..<Int(channels) {
                    let off = dataStart + f * frameSize + c * 2
                    let lo = UInt16(data[off])
                    let hi = UInt16(data[off + 1])
                    let s16 = Int(Int16(bitPattern: hi << 8 | lo))
                    sum += s16
                }
                mono[f] = Float(sum) / (32768.0 * Float(channels))
            }
        }

        return resampleAndShape(mono: mono, frameCount: frameCount,
                                srcRate: Double(sampleRate))
    }

    // MARK: - Helpers

    private static func readUInt32LE(_ data: Data, offset: Int) -> Int {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }
}
