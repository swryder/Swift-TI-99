// Swift 99/a
//
// AudioEngine.swift
// Manages real-time audio output for the emulator using AVAudioEngine.
// Mixes the SN76489 PSG and TMS5220 speech synthesizer into a single
// mono 44.1 kHz stream.
//
// Buffering model: a small pool of pre-allocated AVAudioPCMBuffers is
// kept queued on the AVAudioPlayerNode at all times. When a buffer
// finishes playback, its completion handler refills it from the audio
// sources and reschedules it on the player. Because at least one other
// buffer is always still playing during the refill window, the DAC
// stream is continuous — no silence gap between buffers, which was the
// cause of the periodic chop in the previous single-buffer scheme.
// Int16 scratch arrays are also pre-allocated so the audio path does
// no per-callback heap allocation.

import Foundation
import AVFoundation

/// Protocol for audio sources (PSG, speech) that can fill sample buffers on demand.
protocol AudioSource: AnyObject {
    /// Fill `buffer` with `samples` Int16 samples. `bufferSize` is the byte count.
    func fillAudioBuffer(buffer: UnsafeMutableRawPointer, bufferSize: Int, samples: Int)
}

/// Audio output using AVAudioEngine, supports mixing PSG + Speech into a single mono stream.
final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioSource: AudioSource?
    private var speechSource: AudioSource?
    private let sampleRate: Double = 44100
    private let bufferSize: AVAudioFrameCount = 512
    /// Number of PCM buffers kept in flight on the player node. Three is
    /// enough to absorb completion-handler scheduling jitter; combined
    /// with a 512-sample buffer this gives ~35 ms of total latency.
    private let bufferQueueDepth: Int = 3
    private var isRunning = false
    private var sourcesPrimed = false

    /// Pre-allocated PCM buffer pool. Each buffer is reused indefinitely:
    /// its completion handler refills it and reschedules it.
    private var pcmBuffers: [AVAudioPCMBuffer] = []

    /// Pre-allocated Int16 scratch arrays for source fill + speech mix.
    /// AVAudioPlayerNode delivers buffer-completion callbacks on a serial
    /// queue, so a single shared pair is safe — fills never overlap.
    private var psgInt16: [Int16] = []
    private var speechInt16: [Int16] = []

    func initialize() -> Bool {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = engine, let playerNode = playerNode else { return false }

        engine.attach(playerNode)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Pre-allocate buffer pool and scratch arrays so the audio callback
        // does no allocation in the hot path.
        for _ in 0..<bufferQueueDepth {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                return false
            }
            buf.frameLength = bufferSize
            pcmBuffers.append(buf)
        }
        psgInt16 = [Int16](repeating: 0, count: Int(bufferSize))
        speechInt16 = [Int16](repeating: 0, count: Int(bufferSize))

        do {
            try engine.start()
            playerNode.play()
            isRunning = true
            return true
        } catch {
            print("Audio engine failed to start: \(error)")
            return false
        }
    }

    func setAudioSource(_ source: AudioSource) {
        self.audioSource = source
        primeBuffersIfReady()
    }

    func setSpeechSource(_ source: AudioSource) {
        self.speechSource = source
    }

    /// Fill and schedule every buffer in the pool exactly once. Subsequent
    /// fills are driven by each buffer's completion handler.
    private func primeBuffersIfReady() {
        guard isRunning, !sourcesPrimed, audioSource != nil else { return }
        sourcesPrimed = true
        for buffer in pcmBuffers {
            fillAndSchedule(buffer)
        }
    }

    /// Fill `buffer` from the configured audio sources and schedule it on
    /// the player. The completion handler refills and reschedules the same
    /// buffer, so the queue depth on the player stays at `bufferQueueDepth`.
    private func fillAndSchedule(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let playerNode = playerNode, let source = audioSource else { return }

        if let floatData = buffer.floatChannelData?[0] {
            let samples = Int(bufferSize)

            // Fill PSG audio
            psgInt16.withUnsafeMutableBytes { rawBuf in
                source.fillAudioBuffer(
                    buffer: rawBuf.baseAddress!,
                    bufferSize: samples * 2,
                    samples: samples)
            }

            // Mix speech if available
            if let speech = speechSource {
                speechInt16.withUnsafeMutableBytes { rawBuf in
                    speech.fillAudioBuffer(
                        buffer: rawBuf.baseAddress!,
                        bufferSize: samples * 2,
                        samples: samples)
                }
                for i in 0..<samples {
                    let mixed = Int32(psgInt16[i]) + Int32(speechInt16[i])
                    psgInt16[i] = Int16(max(-32768, min(32767, mixed)))
                }
            }

            // Convert to float
            for i in 0..<samples {
                floatData[i] = Float(psgInt16[i]) / 32768.0
            }
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.fillAndSchedule(buffer)
        }
    }

    var isMuted: Bool = false {
        didSet {
            engine?.mainMixerNode.outputVolume = isMuted ? 0.0 : 1.0
        }
    }

    func shutdown() {
        isRunning = false
        playerNode?.stop()
        engine?.stop()
    }
}
