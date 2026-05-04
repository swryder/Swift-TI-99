// Swift 99/a
//
// Emulator.swift
// Top-level controller that owns the TI994A system and drives execution.
//
// Responsibilities:
//   - Creates and initializes the TI994A system and audio engine
//   - Drives the emulation loop at ~1000 Hz using a DispatchSourceTimer
//     (real-time mode) or a tight async loop (uncapped mode)
//   - Provides wall-clock pacing so the emulator runs at real TI-99/4A speed
//   - Tracks and publishes FPS and CPU MHz statistics for the UI overlay
//   - Manages cartridge insertion/removal, disk mounting, and speech ROM loading
//   - Routes keyboard events from the UI to the TIKeyboard peripheral

import Foundation
import SwiftUI
import Combine

/// Speed mode for the emulator.
enum SpeedMode: String, CaseIterable {
    case realTime = "Real TI-99/4A Speed"
    case uncapped = "Maximum Speed"
}

/// Main controller that owns the emulator system and drives execution.
final class Emulator: ObservableObject {
    let displayBuffer = DisplayBuffer()
    let system = TI994A()

    /// App-wide key event monitor. Catches keyboard events before the
    /// responder chain so input still reaches the emulator even if the
    /// first responder has wandered off (e.g. after a modal panel closes
    /// in Monitor Mode). Lives for the full app lifetime.
    private var keyMonitor: Any?

    init() {
        installKeyMonitor()
    }

    deinit {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self = self else { return event }
            // Pass Cmd-key combos through so menu shortcuts still work.
            if event.modifierFlags.contains(.command) { return event }

            // Let the main menu fire matching key equivalents (e.g. the
            // Keyboard menu's ⌥1…⌥= shortcuts for DEL…QUIT) before we
            // swallow the event for the TI matrix.
            if event.type == .keyDown,
               let menu = NSApp.mainMenu,
               menu.performKeyEquivalent(with: event) {
                return nil
            }

            switch event.type {
            case .keyDown:
                if let chars = event.characters, let char = chars.first {
                    self.handleCharKey(char: char, isDown: true)
                }
                self.handleKey(keyCode: event.keyCode, isDown: true)
                return nil
            case .keyUp:
                if let chars = event.characters, let char = chars.first {
                    self.handleCharKey(char: char, isDown: false)
                }
                self.handleKey(keyCode: event.keyCode, isDown: false)
                return nil
            case .flagsChanged:
                let modifiers: [(NSEvent.ModifierFlags, UInt16)] = [
                    (.shift, 56),    // Left Shift
                    (.control, 59),  // Left Control → TI Control
                    (.option, 58),   // Left Option  → TI Fctn
                ]
                for (flag, code) in modifiers {
                    self.handleKey(keyCode: code,
                                   isDown: event.modifierFlags.contains(flag))
                }
                return nil
            default:
                return event
            }
        }
    }

    @Published var cartridgeName: String?
    @Published var diskNames: [Int: String] = [:]  // drive number -> disk name
    @Published var speechROMLoaded: Bool = false
    @Published var cassetteName: String?
    @Published var cassetteTransportState: CassetteTransportState = .stopped

    // Speed and performance display
    @Published var speedMode: SpeedMode = .realTime
    @Published var showFPS: Bool = false
    @Published var showMHz: Bool = false
    @Published var currentFPS: Double = 0
    @Published var currentMHz: Double = 0

    /// When true, the window hides its chrome and renders only the monitor
    /// bezel — its transparent background lets the desktop show through, and
    /// the user can drag the window from anywhere on the bezel.
    @Published var isMonitorMode: Bool = false
    @Published var isMuted: Bool = false {
        didSet { system.audioEngine?.isMuted = isMuted }
    }

    private var timer: DispatchSourceTimer?
    let emulatorQueue = DispatchQueue(label: "com.swift99a.emulator", qos: .userInteractive)
    private var running = false
    private var uncappedRunning = false

    // Wall-clock anchor for real-time pacing
    private var wallClockBase: CFAbsoluteTime = 0
    private var simTimeBase: Double = 0  // simulated microseconds at wallClockBase

    // Performance tracking
    private var lastStatsTime: CFAbsoluteTime = 0
    private var framesSinceLastStats: Int = 0
    private var cyclesSinceLastStats: Int = 0

    func start() {
        guard !running else { return }

        system.displayBuffer = displayBuffer

        guard system.initSystem() else {
            print("[Swift 99/a] Failed to initialize TI-99/4A system")
            return
        }

        // Auto-load speech ROM from bundle if available
        if let speech = system.pSpeech {
            if let romURL = Bundle.main.url(forResource: "spchrom", withExtension: "bin") {
                let loaded = speech.speechROM.load(from: romURL)
                DispatchQueue.main.async { self.speechROMLoaded = loaded }
            }
        }

        // Initialize audio
        if let audio = system.audioEngine {
            _ = audio.initialize()
            if let psg = system.pPSG {
                audio.setAudioSource(psg)
            }
            if let speech = system.pSpeech {
                audio.setSpeechSource(speech)
            }
            if let cassette = system.pCassette {
                audio.setCassetteSource(cassette)
            }
        }

        running = true
        lastStatsTime = CFAbsoluteTimeGetCurrent()

        startTimer(mode: speedMode)
    }

    /// (Re)start execution for the given speed mode. Mode is passed explicitly
    /// (not read from `self.speedMode`) so that callers from non-main threads
    /// don't race with the `@Published` property update. Must be called on the
    /// emulator queue.
    private func startTimer(mode: SpeedMode) {
        // Stop any existing execution
        timer?.cancel()
        timer = nil
        uncappedRunning = false

        // Reset wall-clock anchor
        wallClockBase = CFAbsoluteTimeGetCurrent()
        simTimeBase = system.currentTimestamp

        if mode == .realTime {
            // Timer fires at ~1000Hz. Each fire runs enough simulated time
            // to catch up with wall-clock elapsed time (capped to avoid
            // spiral-of-death if we fall behind).
            let newTimer = DispatchSource.makeTimerSource(queue: emulatorQueue)
            newTimer.schedule(deadline: .now(), repeating: .microseconds(1000))
            newTimer.setEventHandler { [weak self] in
                guard let self = self, self.running else { return }
                let wallNow = CFAbsoluteTimeGetCurrent()
                let wallElapsed = wallNow - self.wallClockBase
                let targetSimTime = self.simTimeBase + wallElapsed * 1_000_000.0

                // Run in 1ms slices until caught up (cap at 50ms to prevent runaway)
                let maxSimTime = self.system.currentTimestamp + 50_000.0
                let target = min(targetSimTime, maxSimTime)
                while self.system.currentTimestamp < target {
                    _ = self.system.runSystem(microSeconds: 1000)
                }
                self.updateStats()
            }
            newTimer.resume()
            timer = newTimer
        } else {
            // Uncapped: tight loop on emulator queue
            uncappedRunning = true
            emulatorQueue.async { [weak self] in
                self?.uncappedLoop()
            }
        }
    }

    /// Tight execution loop for uncapped speed.
    /// Runs a large batch then re-dispatches to let other queue work
    /// (speed mode changes, cartridge loads, etc.) interleave.
    private func uncappedLoop() {
        guard running && uncappedRunning else { return }

        // Run 100ms of simulated time per batch for maximum throughput
        for _ in 0..<100 {
            _ = system.runSystem(microSeconds: 1000)
        }
        updateStats()

        // Re-dispatch to allow other async work on the serial queue
        emulatorQueue.async { [weak self] in
            self?.uncappedLoop()
        }
    }

    private func updateStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStatsTime
        guard elapsed >= 0.5 else { return }

        let fps = Double(displayBuffer.framesPushed - framesSinceLastStats) / elapsed
        let cycles = system.pCPU?.totalCycleCount ?? 0
        let mhz = Double(cycles - cyclesSinceLastStats) / elapsed / 1_000_000.0

        framesSinceLastStats = displayBuffer.framesPushed
        cyclesSinceLastStats = cycles
        lastStatsTime = now

        DispatchQueue.main.async {
            self.currentFPS = fps
            self.currentMHz = mhz
        }
    }

    func setSpeedMode(_ mode: SpeedMode) {
        let changed = speedMode != mode
        DispatchQueue.main.async { self.speedMode = mode }
        if changed && running {
            // Pass `mode` explicitly so startTimer isn't subject to the
            // ordering race between the main-queue property update above and
            // the emulator-queue startTimer call below.
            emulatorQueue.async { [weak self] in
                self?.startTimer(mode: mode)
            }
        }
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        system.audioEngine?.shutdown()
        _ = system.deInitSystem()
    }

    func handleKey(keyCode: UInt16, isDown: Bool) {
        guard let keyboard = system.pKey else { return }
        if isDown {
            keyboard.keyDown(keyCode: keyCode)
        } else {
            keyboard.keyUp(keyCode: keyCode)
        }
    }

    func handleCharKey(char: Character, isDown: Bool) {
        guard let keyboard = system.pKey else { return }
        if isDown {
            _ = keyboard.handleCharacterDown(char)
        } else {
            _ = keyboard.handleCharacterUp(char)
        }
    }

    // MARK: - Clipboard Paste

    /// True while a paste-from-clipboard operation is in progress.
    @Published var isPasting: Bool = false

    /// Per-character pacing during paste, in seconds. Calibrated for the
    /// real-time TI speed: each key is held for ~3 KSCAN frames (60 Hz) and
    /// released for ~1.5 frames before the next key starts. Anything faster
    /// risks dropped keys; anything in uncapped mode trips the TI's
    /// auto-repeat timer and produces duplicates.
    private let pasteHoldDuration: TimeInterval = 0.050
    private let pasteGapDuration: TimeInterval = 0.025
    private let pastePostNewlinePause: TimeInterval = 0.500

    /// Reads the system pasteboard and types its text into the TI as if the
    /// user pressed each key. Pacing is keyed to the real-time TI frame rate.
    /// No-op if the pasteboard has no plain text or another paste is already
    /// running. Speed mode is *not* touched — at uncapped speed the TI's
    /// auto-repeat timer trips inside the per-key hold and produces dupes.
    func pasteFromClipboard() {
        guard !isPasting else { return }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        pasteText(text)
    }

    /// Schedules synthetic key events for each character in `text` with the
    /// configured pacing. Runs entirely on the main queue.
    func pasteText(_ text: String) {
        guard !isPasting else { return }
        guard let keyboard = system.pKey else { return }

        isPasting = true

        var offset: TimeInterval = 0
        let hold = pasteHoldDuration
        let gap = pasteGapDuration

        for ch in text {
            // Skip characters with no TI representation (silently).
            guard let keys = TIKeyboard.matrixKeys(for: ch) else { continue }

            // Press at offset, release at offset + hold.
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak keyboard] in
                guard let kb = keyboard else { return }
                for k in keys { kb.keyDown(keyCode: k) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + offset + hold) { [weak keyboard] in
                guard let kb = keyboard else { return }
                for k in keys { kb.keyUp(keyCode: k) }
            }

            offset += hold + gap
            // Newline gets extra time so BASIC can tokenize the line before
            // the next characters start arriving.
            if ch == "\n" || ch == "\r" {
                offset += pastePostNewlinePause
            }
        }

        // Final cleanup: clear any lingering keys, drop flag.
        let cleanupAt = offset + 0.020
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupAt) { [weak self] in
            guard let self = self else { return }
            self.system.pKey?.clearAllKeys()
            self.isPasting = false
        }
    }

    /// Briefly press then release a set of Mac key codes on the TI keyboard
    /// matrix. Used by the Keyboard menu to synthesize FCTN+key combos
    /// (DEL, INS, ERASE, etc.) when the menu fires.
    func injectKeys(_ keyCodes: [UInt16]) {
        guard let keyboard = system.pKey else { return }
        for code in keyCodes { keyboard.keyDown(keyCode: code) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let kb = self?.system.pKey else { return }
            for code in keyCodes { kb.keyUp(keyCode: code) }
            // Re-assert any modifiers the user is still physically holding,
            // so an ongoing FCTN/Shift/Ctrl press isn't lost when our
            // synthesized release fires.
            let mods = NSEvent.modifierFlags
            if mods.contains(.option)  { kb.keyDown(keyCode: 58) }
            if mods.contains(.shift)   { kb.keyDown(keyCode: 56) }
            if mods.contains(.control) { kb.keyDown(keyCode: 59) }
        }
    }

    // MARK: - Cartridge Management

    func loadCartridge(from url: URL) {
        loadCartridge(from: [url])
    }

    func loadCartridge(from urls: [URL]) {
        // Clear any stuck keys from the file dialog interaction
        system.pKey?.clearAllKeys()

        do {
            let image = try CartridgeLoader.loadMultiple(from: urls)
            emulatorQueue.sync {
                system.insertCartridge(image)
            }
            DispatchQueue.main.async {
                self.cartridgeName = image.name
            }
        } catch {
            print("[Swift 99/a] Failed to load cartridge: \(error.localizedDescription)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could Not Load Cartridge"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func loadTiCart(from url: URL) {
        // Clear any stuck keys from the file dialog interaction
        system.pKey?.clearAllKeys()

        do {
            let image = try TICartLoader.load(from: url)
            emulatorQueue.sync {
                system.insertCartridge(image)
            }
            DispatchQueue.main.async {
                self.cartridgeName = image.name
            }
        } catch {
            print("[Swift 99/a] Failed to load TiCart: \(error.localizedDescription)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could Not Load TiCart"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func removeCartridge() {
        emulatorQueue.sync {
            system.removeCartridge()
        }
        DispatchQueue.main.async {
            self.cartridgeName = nil
        }
    }

    // MARK: - Disk Management

    func mountDisk(drive: Int, from url: URL) {
        do {
            let image = try DiskImage.load(from: url)
            emulatorQueue.sync {
                system.pDiskDSR?.mountDisk(drive: drive, image: image)
            }
            let name = image.diskName.isEmpty ? url.lastPathComponent : image.diskName
            DispatchQueue.main.async {
                self.diskNames[drive] = name
            }
        } catch {
            print("[Swift 99/a] Failed to mount disk: \(error.localizedDescription)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could Not Mount Disk Image"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func unmountDisk(drive: Int) {
        emulatorQueue.sync {
            system.pDiskDSR?.unmountDisk(drive: drive)
        }
        DispatchQueue.main.async {
            self.diskNames.removeValue(forKey: drive)
        }
    }

    // MARK: - Cassette Tape

    func loadCassette(from url: URL) {
        do {
            let image = try CassetteImage.load(from: url)
            emulatorQueue.sync {
                system.pCassette?.load(image: image)
            }
            DispatchQueue.main.async {
                self.cassetteName = image.displayName
                self.cassetteTransportState = .stopped
            }
        } catch {
            print("[Swift 99/a] Failed to load cassette: \(error.localizedDescription)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could Not Load Cassette Tape"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func ejectCassette() {
        emulatorQueue.sync {
            system.pCassette?.eject()
        }
        DispatchQueue.main.async {
            self.cassetteName = nil
            self.cassetteTransportState = .stopped
        }
    }

    func playCassette() {
        emulatorQueue.sync { system.pCassette?.play() }
        DispatchQueue.main.async { self.cassetteTransportState = .play }
    }

    func stopCassette() {
        emulatorQueue.sync { system.pCassette?.stop() }
        DispatchQueue.main.async { self.cassetteTransportState = .stopped }
    }

    func rewindCassette() {
        emulatorQueue.sync { system.pCassette?.rewind() }
    }

    // MARK: - Speech ROM

    func loadSpeechROM(from url: URL) {
        let success = system.pSpeech?.speechROM.load(from: url) ?? false
        DispatchQueue.main.async {
            self.speechROMLoaded = success
            if !success {
                let alert = NSAlert()
                alert.messageText = "Could Not Load Speech ROM"
                alert.informativeText = "The file could not be read as a valid speech ROM (SPCHROM.BIN)."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
