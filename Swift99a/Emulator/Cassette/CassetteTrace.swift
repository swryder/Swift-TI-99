// Swift 99/a
//
// CassetteTrace.swift
// Comprehensive cycle-keyed event logger that mirrors the Classic99 v1
// instrumentation in tools/classic99_trace/, plus deeper Swift99a-side
// events (memory writes, register snapshots, PC visits) so we can
// pinpoint exactly where the cassette decoder diverges from the working
// reference. Output format is line-oriented so the trace can be diffed
// or scripted against.
//
// Active state machine:
//   - openIfNeeded() lazily opens the trace file on first event
//   - resetClock() rebases the cycle counter to zero when the tape
//     actually starts playing (motor truly transitions on)
//   - 1.5 GB hard cap on the file just so we don't fill the disk
//
// Output: app's Documents container — sandboxed macOS apps can't write
// to ~/Desktop without entitlements. The actual path is printed to
// stdout when the file opens.

import Foundation

enum CassetteTrace {
    // MARK: - State (private)

    private static var fileHandle: FileHandle?
    private static var startCycle: UInt64 = 0
    /// 1.5 GB byte cap — generous so we don't truncate but still bounded.
    private static let byteLimit: UInt64 = 1_500_000_000
    private static var bytesWritten: UInt64 = 0

    /// True once the user-press-PLAY motor-on transition has happened.
    /// Used to gate the noisier event types (memory writes, PC visits) so
    /// the file isn't full of pre-cassette noise.
    static var motorActive: Bool = false

    private static let queue = DispatchQueue(label: "cassette-trace")

    // MARK: - Open / clock

    static func openIfNeeded(currentCycle: Int) {
        queue.sync {
            if fileHandle != nil { return }
            let docs = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            // Timestamp the filename so every load run produces its own
            // trace file. Useful for diff'ing successful vs failed runs
            // when the bug is intermittent — earlier we had to manually
            // copy the file between runs to avoid overwrites.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let stamp = formatter.string(from: Date())
            let url = docs.appendingPathComponent("swift99a_trace_\(stamp).txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else {
                print("[CassetteTrace] FAILED to open trace file at \(url.path)")
                return
            }
            fileHandle = h
            let header = """
            # Swift99a cassette trace (comprehensive)
            # format: cycle event key=value...
            # events:
            #   MOTOR        — CRU motor signal change
            #   LOAD         — WAV/TITape post-processed; first 16 PCM samples
            #   CDIN         — every TB 27 read (post-active-low inversion)
            #   TIMERFIRE    — TMS9901 timer expired and latched
            #   TIMERACK     — CPU wrote to CRU bit 3 (clear timer latch)
            #   INT1ENTRY    — level-1 interrupt taken; saved PC/WP/ST
            #   CRUWRITE     — clock-mode write to timer-load bits 1-14
            #   REGS         — full R0-R15 dump from current WP (gated to
            #                  cassette-active windows only)
            #   PC           — instruction visit at watched PC ranges
            #                  (cassette decode area >1400-15FF)
            #   MEMW         — byte/word write to RAM during cassette mode
            #                  (scratchpad >8300-83FF + cassette PAB area)
            # clock resets when tape actually begins playing

            """
            h.write(header.data(using: .utf8)!)
            startCycle = UInt64(max(0, currentCycle))
            bytesWritten = UInt64(header.count)
            print("[CassetteTrace] writing to \(url.path)")
        }
    }

    static func resetClock(currentCycle: Int) {
        queue.sync {
            guard let h = fileHandle else { return }
            let elapsed = UInt64(max(0, currentCycle)) &- startCycle
            let line = "----- clock reset (was at cycle \(elapsed)) -----\n"
            let data = line.data(using: .utf8)!
            h.write(data)
            bytesWritten &+= UInt64(data.count)
            startCycle = UInt64(max(0, currentCycle))
        }
    }

    // MARK: - Events

    /// Free-form event with details string. The fast path used by every
    /// trace site.
    static func log(currentCycle: Int, event: String, details: String) {
        queue.sync {
            guard let h = fileHandle else { return }
            if bytesWritten > byteLimit { return }
            let cycle = UInt64(max(0, currentCycle))
            let elapsed = cycle &- startCycle
            let line = "\(elapsed) \(event) \(details)\n"
            let data = line.data(using: .utf8)!
            h.write(data)
            bytesWritten &+= UInt64(data.count)
        }
    }

    /// Compact full-register snapshot. Pass the raw 16-byte register file
    /// (or the WP=83E0 contents); we format with all 16 R values.
    static func logRegs(currentCycle: Int, label: String, regs: [UInt16]) {
        guard motorActive else { return }
        var s = label
        for (i, r) in regs.prefix(16).enumerated() {
            s += String(format: " R%d=%04X", i, r)
        }
        log(currentCycle: currentCycle, event: "REGS", details: s)
    }

    /// Memory write inside the cassette/scratchpad windows.
    /// Hot path — gated by `motorActive` and address range so the file
    /// doesn't fill with VDP/sound writes. Two special addresses
    /// (0x83EA, 0x83EB = R5 in the cassette workspace) are ALWAYS logged
    /// so we can see how R5 evolves during cassette setup BEFORE the
    /// motor gate opens — that's where the bad 0xE4 value lands.
    static func logMemWrite(currentCycle: Int, address: Int, data: UInt8, pc: UInt16 = 0) {
        let isR5 = (address == 0x83EA || address == 0x83EB)
        if !isR5 {
            guard motorActive else { return }
            guard address >= 0x8300 && address < 0x8400 else { return }
        }
        let eventName = isR5 ? "MEMW_R5" : "MEMW"
        log(currentCycle: currentCycle, event: eventName,
            details: String(format: "addr=%04X val=%02X pc=%04X", address, data, pc))
    }

    /// PC visit inside cassette code (>1400-15FF). Useful for seeing
    /// which spin-loop branch the ROM is in at any moment.
    static func logPC(currentCycle: Int, pc: UInt16) {
        guard motorActive else { return }
        guard pc >= 0x1400 && pc < 0x1600 else { return }
        log(currentCycle: currentCycle, event: "PC",
            details: String(format: "pc=%04X", pc))
    }
}
