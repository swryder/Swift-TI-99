// Swift 99/a
//
// CassetteImage.swift
// Loaded tape image — the data behind a `.wav` or `.mp3` file.
// Internally we store everything as 8-bit unsigned mono PCM at 16 kHz, the
// same shape Classic99 uses for its tape buffer (see classic99 console/tape.cpp).
// The Cassette device consumes this PCM directly: CDIN is read as
// `pcm[currentPos] >= threshold`, and the same samples are mixed into the
// speaker. WAV files of real TI cassette recordings drop straight in.

import Foundation
import AVFoundation

final class CassetteImage {

    enum Source: Equatable {
        case wav          // 8-bit unsigned PCM decoded from WAV/MP3
    }

    enum LoadError: Error, LocalizedError {
        case unsupportedExtension(String)
        case audioDecodeFailed(String)

        var errorDescription: String? {
            switch self {
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
        case "wav", "wave", "mp3", "m4a", "aif", "aiff", "caf":
            return try loadAudioFile(from: url)
        default:
            throw LoadError.unsupportedExtension(ext)
        }
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
