// Swift 99/a
//
// CassetteTrace.swift
// Lightweight cycle-keyed event logger that mirrors the Classic99 v1
// instrumentation in tools/classic99_trace/. Output format is identical
// (same event names, same key=value field layout) so the two traces can
// be diffed directly to locate the timing divergence in the cassette
// decode path.
//
// Active state machine matches Classic99's:
//   - openIfNeeded() lazily opens the trace file on first event
//   - resetClock() rebases the cycle counter to zero when the tape
//     actually starts playing (motor truly transitions on)
//   - cap of 180M cycles (~60s @ 3MHz) of trace output
//
// Output: ~/Desktop/swift99a_trace.txt (so the file sits next to the
// Classic99 trace for easy diffing).

import Foundation

enum CassetteTrace {
    // MARK: - State (private)

    private static var fileHandle: FileHandle?
    private static var startCycle: UInt64 = 0
    private static let cycleLimit: UInt64 = 180_000_000   // ~60s
    private static let queue = DispatchQueue(label: "cassette-trace")

    // MARK: - Public API

    /// Lazily open the trace file. Safe to call repeatedly.
    /// Sandboxed macOS apps can't write to the real `~/Desktop` without
    /// user-mediated entitlements, so we write inside the app's
    /// Documents container (which is always writable) and print the
    /// absolute path so the user can `cp` it out for comparison.
    static func openIfNeeded(currentCycle: Int) {
        queue.sync {
            if fileHandle != nil { return }
            let docs = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let url = docs.appendingPathComponent("swift99a_trace.txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else {
                print("[CassetteTrace] FAILED to open trace file at \(url.path)")
                return
            }
            fileHandle = h
            let header = """
            # Swift99a cassette trace
            # format: cycle event key=value...
            # events: MOTOR, CDIN, TIMERFIRE, TIMERACK, INT1ENTRY, CRUWRITE, LOAD
            # clock resets when tape actually begins playing

            """
            h.write(header.data(using: .utf8)!)
            startCycle = UInt64(max(0, currentCycle))
            // Print the resolved path so the user can find the file
            // (the sandbox path isn't shown anywhere else).
            print("[CassetteTrace] writing to \(url.path)")
        }
    }

    /// Reset the trace clock to zero — call when the tape actually
    /// begins playing so the cap covers the decode window, not the
    /// boot/load idle.
    static func resetClock(currentCycle: Int) {
        queue.sync {
            guard let h = fileHandle else { return }
            let elapsed = UInt64(max(0, currentCycle)) &- startCycle
            let line = "----- clock reset (was at cycle \(elapsed)) -----\n"
            h.write(line.data(using: .utf8)!)
            startCycle = UInt64(max(0, currentCycle))
        }
    }

    /// Log one event. Free-form `details` for the value portion.
    static func log(currentCycle: Int, event: String, details: String) {
        queue.sync {
            guard let h = fileHandle else { return }
            let cycle = UInt64(max(0, currentCycle))
            let elapsed = cycle &- startCycle
            if elapsed > cycleLimit { return }
            let line = "\(elapsed) \(event) \(details)\n"
            h.write(line.data(using: .utf8)!)
        }
    }
}
